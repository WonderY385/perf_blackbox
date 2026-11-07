@tool
class_name BBHitchDetector
extends RefCounted
## A2 掉帧检测：自适应基线（中位数 + MAD）+ 状态机 + 事件窗口切分。
## 纯逻辑：只吃 (abs_frame, frame_ms)，输出 HitchEvent 字典，方便单测与 headless 复用。

var pre_roll := 120
var post_roll := 60
var merge_gap := 30
var settle := 20
var ratio_threshold := 1.8
var k_sigma := 4.0
var floor_ms := 8.0
var warmup_frames := 120
var baseline_window := 120
var baseline_refresh := 15

const STATE_IDLE := 0
const STATE_OPEN := 1
const STATE_COOLDOWN := 2

var _hist: PackedFloat64Array = PackedFloat64Array()
var _hist_cap := 256
var _frames_seen := 0
var _since_baseline := 0
var _baseline := 0.0
var _threshold := 0.0

var _state := STATE_IDLE
var _onset := -1
var _peak_ms := 0.0
var _peak_frame := -1
var _quiet := 0
var _paused_until := -1

var _events: Array[Dictionary] = []
var _next_id := 1


func baseline_ms() -> float:
	return _baseline


func threshold_ms() -> float:
	return _threshold


func state() -> int:
	return _state


## 前台/后台切换等外部原因造成的巨帧：暂停检测 n 帧
func pause(n: int) -> void:
	if _frames_seen > 0:
		_paused_until = maxi(_paused_until, _frames_seen + n)


func feed(abs_frame: int, frame_ms: float) -> void:
	_push_hist(frame_ms)
	_frames_seen += 1

	if _frames_seen <= warmup_frames:
		return
	_since_baseline += 1
	if _since_baseline >= baseline_refresh or _threshold <= 0.0:
		_since_baseline = 0
		_recompute_baseline()
	if _threshold <= 0.0:
		# 基线尚未建立（样本不足 8 帧），此时任何判定都会把正常帧当成掉帧
		return
	if _paused_until >= _frames_seen:
		_force_quiet_close(abs_frame)
		return
	if _peak_frame >= 0 and _state == STATE_IDLE:
		_peak_frame = -1

	var hot := frame_ms > _threshold
	var cool := frame_ms < _threshold * 0.8

	if frame_ms > _peak_ms or _state == STATE_OPEN:
		if frame_ms > _peak_ms:
			_peak_ms = frame_ms
			_peak_frame = abs_frame

	match _state:
		STATE_IDLE:
			if hot:
				_state = STATE_OPEN
				_onset = abs_frame
				_peak_ms = frame_ms
				_peak_frame = abs_frame
				_quiet = 0
		STATE_OPEN:
			if cool:
				_state = STATE_COOLDOWN
				_quiet = 1
			else:
				_quiet = 0
		STATE_COOLDOWN:
			if hot:
				_state = STATE_OPEN
				_quiet = 0
			else:
				_quiet += 1
				if _quiet >= settle:
					_close_event(abs_frame)
		_:
			_state = STATE_IDLE


func _force_quiet_close(abs_frame: int) -> void:
	if _state == STATE_OPEN or _state == STATE_COOLDOWN:
		_close_event(abs_frame)


func _close_event(abs_frame: int) -> void:
	var ev := _build_event(abs_frame)
	if not ev.is_empty():
		_events.append(ev)
	_state = STATE_IDLE
	_onset = -1
	_peak_ms = 0.0
	_quiet = 0
	# 保留 _peak_frame 供上层关联；下一次 IDLE→OPEN 时重置


func _build_event(abs_frame: int) -> Dictionary:
	if _peak_frame < 0 or _onset < 0:
		return {}
	var base := maxf(_baseline, 0.001)
	var ratio := _peak_ms / base
	var start := maxi(0, _onset - pre_roll)
	var end := abs_frame + post_roll
	var ev := {
		"id": "evt_%04d" % _next_id,
		"start_frame": start,
		"onset_frame": _onset,
		"peak_frame": _peak_frame,
		"end_frame": end,
		"pre_roll": pre_roll,
		"peak_ms": snappedf(_peak_ms, 0.001),
		"baseline_ms": snappedf(_baseline, 0.001),
		"ratio": snappedf(ratio, 0.01),
		"severity": BBSchema.severity_for(ratio, _peak_ms),
		"bookmark": null,
		"tags": [],
		"confidence": 1.0 if not _assume_degraded else 0.6,
	}
	_next_id += 1
	return ev


var _assume_degraded := false


func set_degraded(v: bool) -> void:
	_assume_degraded = v


func _push_hist(frame_ms: float) -> void:
	if _hist.size() < _hist_cap:
		_hist.append(frame_ms)
	else:
		_hist[_frames_seen % _hist_cap] = frame_ms


func _recent(n: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var size := _hist.size()
	var take := mini(n, size)
	if take <= 0:
		return out
	out.resize(take)
	var start := size - take
	for i in take:
		out[i] = _hist[(start + i) % _hist_cap]
	return out


func _recompute_baseline() -> void:
	var recent := _recent(baseline_window)
	if recent.size() < 8:
		return
	var med := BBStats.median(recent)
	var sigma := BBStats.robust_sigma(recent, med)
	_baseline = med
	_threshold = maxf(maxf(med * ratio_threshold, med + k_sigma * sigma), floor_ms)


func pop_events() -> Array[Dictionary]:
	var out := _events.duplicate()
	_events.clear()
	return out


## 停止采集时收尾：把仍开着的事件强制闭合
func force_close(abs_frame: int) -> Array[Dictionary]:
	if _state != STATE_IDLE:
		_close_event(abs_frame)
	return pop_events()


## 不改变状态，只读取当前是否已积累事件
func has_open_event() -> bool:
	return _state != STATE_IDLE

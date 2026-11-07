@tool
class_name BBOverheadGuard
extends RefCounted
## A3 自身开销守卫：插件不能自己造成掉帧，且降级必须可见（不许静默）。

const LEVEL_NONE := 0
const LEVEL_NO_SHOTS := 1
const LEVEL_SAMPLE_HALF := 2
const LEVEL_SAMPLE_QUARTER := 3
const LEVEL_PROBE_COUNT_ONLY := 4
const LEVEL_PROBE_OFF := 5

var budget_ms := 0.5
var window_frames := 60

var level := LEVEL_NONE
var degradations: PackedStringArray = PackedStringArray()

var _sum_us := 0.0
var _n := 0
var _last_mean_ms := 0.0


## 返回 true 表示本帧发生了降级（调用方负责 push_warning + 记 manifest）
func feed(overhead_us: float) -> bool:
	_sum_us += overhead_us
	_n += 1
	if _n < window_frames:
		return false
	var mean_ms := _sum_us / float(_n) / 1000.0
	_last_mean_ms = mean_ms
	_sum_us = 0.0
	_n = 0
	if mean_ms <= budget_ms:
		return false
	if level >= LEVEL_PROBE_OFF:
		return false
	level += 1
	degradations.append("%s (overhead %.3f ms > %.3f ms)" % [_level_name(level), mean_ms, budget_ms])
	return true


func mean_ms() -> float:
	return _last_mean_ms


func sample_stride() -> int:
	match level:
		LEVEL_SAMPLE_HALF:
			return 2
		LEVEL_SAMPLE_QUARTER:
			return 4
		_:
			return 1


func shots_enabled() -> bool:
	return level < LEVEL_NO_SHOTS


func probe_mode() -> String:
	if level >= LEVEL_PROBE_OFF:
		return "off"
	if level >= LEVEL_PROBE_COUNT_ONLY:
		return "count"
	return "time"


func state() -> Dictionary:
	return {
		"level": level,
		"mean_ms": snappedf(_last_mean_ms, 0.001),
		"budget_ms": budget_ms,
		"degradations": Array(degradations),
	}


func _level_name(l: int) -> String:
	match l:
		LEVEL_NO_SHOTS:
			return "关闭事件帧截图"
		LEVEL_SAMPLE_HALF:
			return "采样降频 1/2"
		LEVEL_SAMPLE_QUARTER:
			return "采样降频 1/4"
		LEVEL_PROBE_COUNT_ONLY:
			return "探针降为纯计数"
		LEVEL_PROBE_OFF:
			return "关闭探针（B1 不可用）"
		_:
			return "正常"

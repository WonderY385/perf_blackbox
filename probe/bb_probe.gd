@tool
class_name BBProbe
extends RefCounted
## B1 探针：全 static，调用方只写一行 BBProbe.count("Class::func")。
## 性能设计：
##   - id 首次出现时解析成 int，之后只走 Packed 数组下标；
##   - 计数模式 = 一次 int 自增 + 一次「本帧是否首次触达」判断；
##   - 计时模式额外两次 Time.get_ticks_usec，self time 用「父-子」扣减。

## 是否启用（由 BB.start_capture 打开）
static var _enabled := false
static var _time_mode := false

## String -> int
static var _ids: Dictionary = {}
static var _names: PackedStringArray = PackedStringArray()
static var _calls: PackedInt32Array = PackedInt32Array()
static var _self_us: PackedInt64Array = PackedInt64Array()
static var _touched: PackedInt32Array = PackedInt32Array()
static var _frame_total_calls := 0

## 计时模式栈
static var _stack_ids: PackedInt32Array = PackedInt32Array()
static var _stack_child_us: PackedInt64Array = PackedInt64Array()

## 帧级稀疏表：abs -> {"c": {id:int calls}, "u": {id:int us}}
static var _frame_cap := 2048
static var _frames: Array = []
static var _frames_total := 0


static func set_enabled(v: bool) -> void:
	_enabled = v
	if not v:
		reset_frame_state()


static func enabled() -> bool:
	return _enabled


static func set_time_mode(v: bool) -> void:
	_time_mode = v


static func time_mode() -> bool:
	return _time_mode


static func reset() -> void:
	_ids.clear()
	_names = PackedStringArray()
	_calls = PackedInt32Array()
	_self_us = PackedInt64Array()
	_touched = PackedInt32Array()
	_stack_ids = PackedInt32Array()
	_stack_child_us = PackedInt64Array()
	_frames = []
	_frames_total = 0
	_frame_total_calls = 0
	_time_mode = false
	_enabled = false


static func reset_frame_state() -> void:
	_touched = PackedInt32Array()
	_stack_ids = PackedInt32Array()
	_stack_child_us = PackedInt64Array()
	_frame_total_calls = 0


static func id_count() -> int:
	return _names.size()


static func id_name(i: int) -> String:
	if i < 0 or i >= _names.size():
		return ""
	return _names[i]


static func _resolve(id: String) -> int:
	var i: int = _ids.get(id, -1)
	if i >= 0:
		return i
	i = _names.size()
	_ids[id] = i
	_names.append(id)
	_calls.append(0)
	_self_us.append(0)
	return i


## 计数：唯一要求用户手写的探针调用
static func count(id: String) -> void:
	if not _enabled:
		return
	var i := _resolve(id)
	if _calls[i] == 0:
		_touched.append(i)
	_calls[i] += 1
	_frame_total_calls += 1


static func begin(id: String) -> int:
	if not _enabled or not _time_mode:
		return 0
	var i := _resolve(id)
	var t := Time.get_ticks_usec()
	_stack_ids.append(i)
	_stack_child_us.append(0)
	return t


static func end(id: String, t0: int) -> void:
	if not _enabled or not _time_mode:
		return
	var dur := Time.get_ticks_usec() - t0
	var depth := _stack_ids.size()
	if depth == 0:
		return
	var i := _stack_ids[depth - 1]
	var child := _stack_child_us[depth - 1]
	_stack_ids.remove_at(depth - 1)
	_stack_child_us.remove_at(depth - 1)
	if _calls[i] == 0:
		_touched.append(i)
	_calls[i] += 1
	_frame_total_calls += 1
	_self_us[i] += maxi(dur - child, 0)
	if depth >= 2:
		_stack_child_us[depth - 2] += dur


## 帧末由采集器调用：把帧内累计并入帧级稀疏表
static func flush_frame(abs_frame: int) -> void:
	var c := {}
	var u := {}
	for i in _touched:
		c[i] = _calls[i]
		if _time_mode and _self_us[i] > 0:
			u[i] = _self_us[i]
		_calls[i] = 0
		_self_us[i] = 0
	_touched = PackedInt32Array()
	_frame_total_calls = 0
	if _frames.size() < _frame_cap:
		_frames.append(null)
	var entry := {"abs": abs_frame, "c": c, "u": u}
	_frames[abs_frame % _frame_cap] = entry
	_frames_total = maxi(_frames_total, abs_frame + 1)


## 取某帧的探针数据；越界/未覆盖返回 {}
static func frame_data(abs_frame: int) -> Dictionary:
	if abs_frame < 0:
		return {}
	var idx := abs_frame % _frame_cap
	# 注意：环没填满时 _frames.size() < _frame_cap，不能用「填满」当就绪条件
	if idx >= _frames.size():
		return {}
	var e = _frames[idx]
	if e == null or int(e.get("abs", -1)) != abs_frame:
		return {}
	return e


## 帧级调用总数（自诊断列）
static func frame_total_calls(abs_frame: int) -> int:
	var e := frame_data(abs_frame)
	if e.is_empty():
		return 0
	var total := 0
	for k in e["c"]:
		total += int(e["c"][k])
	return total


static func frames_total() -> int:
	return _frames_total

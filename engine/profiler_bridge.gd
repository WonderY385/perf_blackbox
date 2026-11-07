@tool
class_name BBProfilerBridge
extends EngineProfiler
## 引擎 profiler 桥（把逐帧 process/physics 时间接进采样器）。
##
## 背景（别推翻）：`EngineDebugger.is_active()` 只有在**调试器真的挂着**时才为 true；
## 导出包/普通运行时它恒 false，此时 `register_profiler` 是空操作、`_tick` 不会来。
## 所以这里提供的是「有调试器时多两列真实数据，没有时继续写 -1」，绝不假装有值。
##
## 用法（由 BBCaptureSession 自动调用，用户不用管）：
##   if BBProfilerBridge.install():
##       var latest := BBProfilerBridge.latest()   # {frame_time, process_ms, physics_ms, physics_frame_ms}
##   BBProfilerBridge.uninstall()

static var _instance: EngineProfiler = null
static var _enabled := false
static var _latest := {
	"frame_time": -1.0,
	"process_ms": -1.0,
	"physics_ms": -1.0,
	"physics_frame_ms": -1.0,
	"usable": false,
}

const PROFILER_NAME := &"bb_tick"


static func is_live() -> bool:
	return _instance != null and _enabled


static func latest() -> Dictionary:
	return _latest


## 只有在调试器可用时才注册；返回是否成功（false 表示环境不支持，列保持 -1）。
static func install() -> bool:
	if _instance != null:
		return _enabled
	if not EngineDebugger.is_active():
		return false
	var bridge := BBProfilerBridge.new()
	if bridge == null:
		return false
	EngineDebugger.register_profiler(PROFILER_NAME, bridge)
	EngineDebugger.profiler_enable(PROFILER_NAME, true)
	_instance = bridge
	_enabled = true
	return true


static func uninstall() -> void:
	if _instance == null:
		return
	EngineDebugger.profiler_enable(PROFILER_NAME, false)
	EngineDebugger.unregister_profiler(PROFILER_NAME)
	_instance = null
	_enabled = false
	_latest = {
		"frame_time": -1.0,
		"process_ms": -1.0,
		"physics_ms": -1.0,
		"physics_frame_ms": -1.0,
		"usable": false,
	}


# --- EngineDebugger 回调（引擎调用，不是我们主动调） ---

func _toggle(enable: bool, options: Array) -> void:
	_enabled = enable


func _add_frame(data: Array) -> void:
	# 引擎默认的 "servers" profiler 才会走这里；我们不用它推送逐帧数组。
	pass


func _tick(frame_time: float, process_time: float, physics_time: float, physics_frame_time: float) -> void:
	# 单位：秒（引擎内部是 double 秒），统一换成毫秒给采样器。
	_latest = {
		"frame_time": frame_time * 1000.0,
		"process_ms": process_time * 1000.0,
		"physics_ms": physics_time * 1000.0,
		"physics_frame_ms": physics_frame_time * 1000.0,
		"usable": true,
	}

@tool
class_name BBFrameSampler
extends RefCounted
## A1 逐帧采样器：每帧只做固定次数的公开 API 读取 + 一段 Packed 数组写入。
## 数据源优先级：Time（一定可用）> RenderingServer 测量（要开 measure）> Performance monitor（可能恒 0）。
## 任一数据源不可用时写 -1（BBSchema.UNAVAILABLE），绝不写 0 冒充测量值。

const PROBE_MONITOR_FRAMES := 4

var ring: BBRingBuffer

## 由 engine/profiler_bridge.gd 注入；没有调试器时保持 -1
var profiler_process_ms := -1.0
var profiler_physics_ms := -1.0

var unavailable := {}  ## 列名 -> 原因

var _row := PackedFloat64Array()
var _last_t_us := -1
var _vprid := RID()
var _measure_on := false
var _monitor_probe_frames := 0
var _monitor_ok := {}
var _pipeline_cum_prev := -1.0

var _c := BBSchema.COL


func _init(capacity := 1800) -> void:
	ring = BBRingBuffer.new(PackedStringArray(BBSchema.COLUMNS), capacity)
	_row.resize(BBSchema.COLUMNS.size())
	_row.fill(0.0)


func attach(tree: SceneTree) -> void:
	if tree == null:
		return
	var vp := tree.root
	if vp == null:
		return
	_vprid = vp.get_viewport_rid()
	if RenderingServer.has_method("viewport_set_measure_render_time"):
		RenderingServer.viewport_set_measure_render_time(_vprid, true)
		_measure_on = true
	if DisplayServer.get_name() == "headless":
		_mark_unavailable("render_cpu_ms", "headless 渲染器无 GPU 计时")
		_mark_unavailable("render_gpu_ms", "headless 渲染器无 GPU 计时")
		_mark_unavailable("draw_calls", "headless 渲染器无绘制统计")
		_mark_unavailable("objects", "headless 渲染器无绘制统计")
		_mark_unavailable("primitives", "headless 渲染器无绘制统计")
		_mark_unavailable("video_mem_kb", "headless 渲染器无显存统计")
		_mark_unavailable("texture_mem_kb", "headless 渲染器无显存统计")
		_mark_unavailable("buffer_mem_kb", "headless 渲染器无显存统计")


func detach() -> void:
	if _measure_on and _vprid.is_valid():
		RenderingServer.viewport_set_measure_render_time(_vprid, false)
	_measure_on = false


func _mark_unavailable(col: String, reason: String) -> void:
	unavailable[col] = reason


func is_available(col: String) -> bool:
	return not unavailable.has(col)


## 一次采样。返回 {frame_ms, overhead_us}
## light = true 时跳过所有 Performance monitor 读取（A3 降级档位用），对应列填 -1
func sample(abs_frame: int, light := false) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	_row[_c["t_us"]] = float(t0)

	var frame_ms := 0.0
	if _last_t_us >= 0:
		frame_ms = float(t0 - _last_t_us) / 1000.0
	_last_t_us = t0
	_row[_c["frame_ms"]] = frame_ms

	# process/physics：只有 EngineProfiler 回调可用时才不是 -1
	if BBProfilerBridge.is_live():
		var bridge_data := BBProfilerBridge.latest()
		if bool(bridge_data.get("usable", false)):
			profiler_process_ms = float(bridge_data.get("process_ms", -1.0))
			profiler_physics_ms = float(bridge_data.get("physics_ms", -1.0))
	_row[_c["process_ms"]] = profiler_process_ms
	_row[_c["physics_ms"]] = profiler_physics_ms

	# 渲染计时（上一帧的值，lag=1）
	if _measure_on and is_available("render_cpu_ms"):
		var cpu := float(RenderingServer.viewport_get_measured_render_time_cpu(_vprid))
		var gpu := float(RenderingServer.viewport_get_measured_render_time_gpu(_vprid))
		_row[_c["render_cpu_ms"]] = cpu
		_row[_c["render_gpu_ms"]] = gpu
	else:
		_row[_c["render_cpu_ms"]] = BBSchema.UNAVAILABLE
		_row[_c["render_gpu_ms"]] = BBSchema.UNAVAILABLE

	# 渲染统计
	if light:
		# 降级档位：monitor 读取全部跳过（这是本采样器最贵的一段）
		for col_name in ["draw_calls", "objects", "primitives", "video_mem_kb", "texture_mem_kb",
				"buffer_mem_kb", "node_count", "object_count", "resource_count",
				"phys_active", "phys_pairs", "pipeline_delta"]:
			_row[_c[col_name]] = BBSchema.UNAVAILABLE
		_row[_c["probe_calls"]] = float(BBProbe.frame_total_calls(abs_frame))
		var overhead_light := float(Time.get_ticks_usec() - t0)
		_row[_c["overhead_us"]] = overhead_light
		ring.write_row(abs_frame, _row)
		return {"frame_ms": frame_ms, "overhead_us": overhead_light}

	_row[_c["draw_calls"]] = _monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME, "draw_calls")
	_row[_c["objects"]] = _monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME, "objects")
	_row[_c["primitives"]] = _monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME, "primitives")
	_row[_c["video_mem_kb"]] = _monitor(Performance.RENDER_VIDEO_MEM_USED, "video_mem_kb")
	_row[_c["texture_mem_kb"]] = _monitor(Performance.RENDER_TEXTURE_MEM_USED, "texture_mem_kb")
	_row[_c["buffer_mem_kb"]] = _monitor(Performance.RENDER_BUFFER_MEM_USED, "buffer_mem_kb")

	# 管线编译：累计值 → 一阶差分（直接读累计值会永远"很大"）
	var cum := _pipeline_cumulative()
	if cum < 0.0:
		_row[_c["pipeline_delta"]] = BBSchema.UNAVAILABLE
		_pipeline_cum_prev = -1.0
	else:
		if _pipeline_cum_prev < 0.0:
			_row[_c["pipeline_delta"]] = 0.0
		else:
			_row[_c["pipeline_delta"]] = maxf(cum - _pipeline_cum_prev, 0.0)
		_pipeline_cum_prev = cum

	_row[_c["node_count"]] = _monitor(Performance.OBJECT_NODE_COUNT, "node_count")
	_row[_c["object_count"]] = _monitor(Performance.OBJECT_COUNT, "object_count")
	_row[_c["resource_count"]] = _monitor(Performance.OBJECT_RESOURCE_COUNT, "resource_count")

	_row[_c["phys_active"]] = _monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS, "phys_active")
	_row[_c["phys_pairs"]] = _monitor(Performance.PHYSICS_3D_COLLISION_PAIRS, "phys_pairs")

	_row[_c["probe_calls"]] = float(BBProbe.frame_total_calls(abs_frame))

	var overhead_us := float(Time.get_ticks_usec() - t0)
	_row[_c["overhead_us"]] = overhead_us

	ring.write_row(abs_frame, _row)
	_monitor_probe_frames += 1
	return {"frame_ms": frame_ms, "overhead_us": overhead_us}


## monitor 读取 + 可用性探测：连续 4 帧全 0 且非 headless → 判不可用（部分后端恒 0）
func _monitor(id: int, col: String) -> float:
	if unavailable.has(col):
		return BBSchema.UNAVAILABLE
	var v := float(Performance.get_monitor(id))
	if v != 0.0:
		_monitor_ok[col] = true
	elif _monitor_probe_frames >= PROBE_MONITOR_FRAMES and not _monitor_ok.has(col):
		if _monitor_probe_frames == PROBE_MONITOR_FRAMES:
			_mark_unavailable(col, "该平台/渲染后端的此 monitor 恒 0（探测 %d 帧）" % PROBE_MONITOR_FRAMES)
		return BBSchema.UNAVAILABLE
	return v


func _pipeline_cumulative() -> float:
	if unavailable.has("draw_calls"):
		return BBSchema.UNAVAILABLE
	var total := 0.0
	total += float(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))
	total += float(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH))
	total += float(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE))
	total += float(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW))
	return total

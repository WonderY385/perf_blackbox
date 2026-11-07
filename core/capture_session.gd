@tool
class_name BBCaptureSession
extends RefCounted
## 一次采集的生命周期：采样 → 检测 → 归因 → 组装内存包。
## 这里是 A/B/C 三层唯一的粘合点；所有模块都可单独测试（不依赖它）。

const MIN_BASELINE_FRAMES := 8

var sampler: BBFrameSampler
var detector: BBHitchDetector
var guard: BBOverheadGuard
var entities: BBEntityDelta

var opts: Dictionary = {}
var running := false
var frame := 0
var tree: SceneTree
var started_us := 0

var events: Array[Dictionary] = []
var deltas: Dictionary = {}
var marks: Dictionary = {}

var profiler_bridge_live := false

var _focus_conn := false


func start(t: SceneTree, options := {}) -> void:
	opts = options.duplicate()
	tree = t
	var ring := int(opts.get("ring", 1800))

	sampler = BBFrameSampler.new(ring)
	sampler.attach(t)
	# 有调试器时才注册（导出包/普通运行时 is_active() 恒 false，注册是空操作）
	profiler_bridge_live = BBProfilerBridge.install()

	detector = BBHitchDetector.new()
	detector.pre_roll = int(opts.get("pre_roll", detector.pre_roll))
	detector.post_roll = int(opts.get("post_roll", detector.post_roll))
	detector.merge_gap = int(opts.get("merge_gap", detector.merge_gap))
	detector.settle = int(opts.get("settle", detector.settle))
	detector.warmup_frames = int(opts.get("warmup_frames", detector.warmup_frames))
	detector.ratio_threshold = float(opts.get("ratio_threshold", detector.ratio_threshold))

	guard = BBOverheadGuard.new()
	guard.budget_ms = float(opts.get("overhead_budget_ms", guard.budget_ms))

	entities = BBEntityDelta.new()
	entities.attach(t)
	entities.begin_frame(0)

	BBProbe.reset()
	var probe_mode := String(opts.get("probe", "count"))
	BBProbe.set_enabled(probe_mode != "off")
	BBProbe.set_time_mode(probe_mode == "time")

	if t != null and t.root != null and t.root.has_signal("focus_exited"):
		if not t.root.focus_exited.is_connected(_on_focus_exited):
			t.root.focus_exited.connect(_on_focus_exited)
			_focus_conn = true

	frame = 0
	running = true
	started_us = Time.get_ticks_usec()
	events.clear()
	deltas.clear()
	marks.clear()


func _on_focus_exited() -> void:
	# 最小化/切后台会制造巨大 frame_ms，暂停检测 30 帧（别把用户切窗口记成卡顿）
	if detector != null:
		detector.pause(30)


func is_capturing() -> bool:
	return running


func elapsed_ms() -> float:
	return float(Time.get_ticks_usec() - started_us) / 1000.0


func mark(label: String) -> void:
	marks[frame] = label


## 由 BB._process（process_priority = 1000）每帧调用
func on_frame() -> void:
	if not running:
		return
	var abs_frame := frame
	# 本帧内发生的 node_added 已在上帧末开好了桶
	entities.end_frame(abs_frame)
	entities.begin_frame(abs_frame + 1)

	var light := guard.sample_stride() > 1
	var sample := sampler.sample(abs_frame, light)
	detector.feed(abs_frame, float(sample["frame_ms"]))
	BBProbe.flush_frame(abs_frame)

	var degraded := guard.feed(float(sample["overhead_us"]))
	if degraded:
		var mode := guard.probe_mode()
		BBProbe.set_enabled(mode != "off")
		BBProbe.set_time_mode(mode == "time")
		push_warning("[Perf Blackbox] 自身开销超预算，已降级至 L%d（%s）" % [guard.level, ", ".join(guard.degradations)])

	for ev in detector.pop_events():
		_finalize_event(ev)

	frame += 1


func _finalize_event(ev: Dictionary) -> void:
	var oldest := sampler.ring.oldest_abs()
	var peak := int(ev.get("peak_frame", -1))
	var win_from: int = maxi(oldest, int(ev.get("start_frame", 0)))
	var win_to: int = mini(frame - 1, int(ev.get("end_frame", frame - 1)))
	if win_to - win_from < 4:
		win_from = maxi(oldest, win_to - 8)
	var base_to := win_from - 1
	var base_from := maxi(oldest, base_to - detector.baseline_window + 1)

	var scripts := BBProbeDelta.compute(base_from, base_to, win_from, win_to)
	var ents := entities.delta_for(base_from, base_to, win_from, win_to)
	var counters := BBCounterDelta.compute(sampler.ring, base_from, base_to, win_from, win_to)

	var low_conf := (base_to - base_from) < MIN_BASELINE_FRAMES * 3 or guard.level > 0
	var ctx := {
		"peak_frame": peak,
		"low_confidence": low_conf,
		"unavailable": Array(sampler.unavailable.keys()),
	}
	var ranked := BBCauseRanker.rank({"scripts": scripts, "entities": ents, "counters": counters}, ctx)

	ev["window"] = [win_from, win_to]
	ev["baseline_window"] = [base_from, base_to]
	ev["tags"] = _infer_tags(ents, counters, scripts)
	ev["bookmark"] = _bookmark_in(win_from, win_to)
	ev["confidence"] = ranked["confidence"]

	_maybe_merge(ev, ranked, scripts, ents, counters)
	if ev.get("merged_into", "") != "":
		return

	events.append(ev)
	deltas[ev["id"]] = {
		"baseline_window": [base_from, base_to],
		"window": [win_from, win_to],
		"scripts": scripts,
		"entities": ents,
		"counters": counters,
		"root_cause": ranked["root_cause"],
		"confidence": ranked["confidence"],
		"ranking": ranked["ranked"],
		"excluded": ranked["excluded"],
		"notes": ranked["notes"],
	}


## 两段卡顿间隔 < merge_gap → 视为同一事件（保持「一次卡顿 = 一个事件」）
func _maybe_merge(ev: Dictionary, _ranked: Dictionary, _scripts: Array, _ents: Array, _counters: Array) -> void:
	if events.is_empty():
		return
	var last: Dictionary = events[events.size() - 1]
	var gap := int(ev["onset_frame"]) - int(last["end_frame"])
	if gap <= 0:
		gap = int(ev["start_frame"]) - int(last["end_frame"])
	if gap > detector.merge_gap:
		return
	if float(ev["peak_ms"]) > float(last["peak_ms"]):
		last["peak_ms"] = ev["peak_ms"]
		last["peak_frame"] = ev["peak_frame"]
		last["ratio"] = ev["ratio"]
		last["severity"] = ev["severity"]
	last["end_frame"] = maxi(int(last["end_frame"]), int(ev["end_frame"]))
	last["merged"] = int(last.get("merged", 1)) + 1
	ev["merged_into"] = last["id"]


func _infer_tags(ents: Array, counters: Array, scripts: Array) -> Array:
	var tags: Array = []
	var scene_added := false
	for e in ents:
		if String(e.get("kind", "")) == "scene" and int(e.get("added", 0)) > 0:
			scene_added = true
			break
	if scene_added:
		tags.append("scene_load")
	for c in counters:
		match String(c.get("key", "")):
			"pipeline_delta":
				tags.append("pipeline_compile")
			"phys_pairs":
				tags.append("physics_spike")
			_:
				pass
	if not scripts.is_empty():
		tags.append("script_spike")
	return tags


func _bookmark_in(win_from: int, win_to: int) -> Variant:
	for f in marks:
		if int(f) >= win_from and int(f) <= win_to:
			return marks[f]
	return null


func stop() -> Dictionary:
	if not running:
		return {}
	running = false
	for ev in detector.force_close(maxi(frame - 1, 0)):
		_finalize_event(ev)
	if tree != null and tree.root != null and _focus_conn:
		if tree.root.focus_exited.is_connected(_on_focus_exited):
			tree.root.focus_exited.disconnect(_on_focus_exited)
		_focus_conn = false
	entities.detach()
	sampler.detach()
	BBProbe.set_enabled(false)
	BBProfilerBridge.uninstall()
	profiler_bridge_live = false
	return build_pack()


func build_pack() -> Dictionary:
	var oldest := sampler.ring.oldest_abs()
	var frames := sampler.ring.total - oldest
	var data := sampler.ring.snapshot()

	var snapshot := {}
	for ev in events:
		var w: Array = ev.get("window", [0, 0])
		snapshot[ev["id"]] = entities.scene_fingerprint(int(w[0]), int(w[1]))

	var manifest := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"tool": {"name": BBSchema.TOOL_NAME, "version": BBSchema.TOOL_VERSION, "api_version": BBSchema.API_VERSION},
		"engine": _engine_info(),
		"env": _env_info(),
		"settings_hash": _settings_hash(),
		"measure_preconditions": {
			"vsync": _vsync_name(),
			"max_fps": Engine.max_fps,
			"headless": DisplayServer.get_name() == "headless",
		},
		"project": {"name_hashed": _hash_string(String(ProjectSettings.get_setting("application/config/name", "unknown")))},
		"capture": {
			"start_frame": oldest,
			"frames": frames,
			"capacity": sampler.ring.capacity,
			"elapsed_ms": snappedf(elapsed_ms(), 1.0),
			"columns": BBSchema.COLUMNS,
			"degradations": Array(guard.degradations),
			"probe_mode": guard.probe_mode(),
		},
		"event_count": events.size(),
		"budgets": [],
		"diagnostics": {
			"unavailable_columns": sampler.unavailable,
			"unavailable_sources": BBSchema.UNAVAILABLE_SOURCES,
			"overhead": guard.state(),
			"probe_ids": BBProbe.id_count(),
			"probe_frames": BBProbe.frames_total(),
			"profiler_bridge": profiler_bridge_live,
			"profiler_bridge_note": ("EngineProfiler 已接入：process_ms/physics_ms 为实测"
				if profiler_bridge_live else
				"无调试器（EngineDebugger.is_active()=false）：process_ms/physics_ms 恒为 -1"),
		},
	}

	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"manifest": manifest,
		"columns": PackedStringArray(BBSchema.COLUMNS),
		"start_frame": oldest,
		"frames": frames,
		"data": data,
		"events": events.duplicate(true),
		"deltas": deltas.duplicate(true),
		"scene_snapshot": snapshot,
		"marks": marks.duplicate(),
	}


func event_summary() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ev in events:
		var d: Dictionary = deltas.get(ev["id"], {})
		out.append({
			"id": ev["id"],
			"peak_frame": ev["peak_frame"],
			"peak_ms": ev["peak_ms"],
			"baseline_ms": ev["baseline_ms"],
			"ratio": ev["ratio"],
			"severity": ev["severity"],
			"tags": ev["tags"],
			"bookmark": ev["bookmark"],
			"root_cause": d.get("root_cause", "inconclusive"),
			"confidence": ev.get("confidence", 0.0),
		})
	return out


func get_event(id: String) -> Dictionary:
	for ev in events:
		if String(ev["id"]) == id:
			var out: Dictionary = ev.duplicate(true)
			out["delta"] = deltas.get(id, {})
			out["schema_version"] = BBSchema.SCHEMA_VERSION
			return out
	return {}


func _engine_info() -> Dictionary:
	var v := Engine.get_version_info()
	var renderer := ""
	var driver := ""
	if RenderingServer.has_method("get_current_rendering_method"):
		renderer = String(RenderingServer.get_current_rendering_method())
	if RenderingServer.has_method("get_current_rendering_driver_name"):
		driver = String(RenderingServer.get_current_rendering_driver_name())
	return {
		"version": String(v.get("string", "")),
		"renderer": renderer,
		"driver": driver,
		"physics": String(ProjectSettings.get_setting("physics/3d/physics_engine", "")),
	}


func _env_info() -> Dictionary:
	return {
		"os": OS.get_name(),
		"os_version": OS.get_version(),
		"gpu": RenderingServer.get_video_adapter_name() if RenderingServer.has_method("get_video_adapter_name") else "",
		"cpu_cores": OS.get_processor_count(),
	}


func _vsync_name() -> String:
	var mode := DisplayServer.window_get_vsync_mode()
	match mode:
		DisplayServer.VSYNC_DISABLED:
			return "disabled"
		DisplayServer.VSYNC_ENABLED:
			return "enabled"
		DisplayServer.VSYNC_ADAPTIVE:
			return "adaptive"
		_:
			return "mode_%d" % mode


func _settings_hash() -> String:
	var parts := [
		String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		String(ProjectSettings.get_setting("physics/3d/physics_engine", "")),
		_vsync_name(),
		str(Engine.max_fps),
	]
	return _hash_string("|".join(parts))


static func _hash_string(s: String) -> String:
	return "h%08x" % int(hash(s) & 0x7fffffff)

@tool
extends Node
## Perf Blackbox 运行时单例（Autoload 名 `BB`）。
## 职责边界：只做「生命周期 + 出口」，不做测量与归因——那些在 core/attribution/artifact 里，
## 这样 CI 与单测可以在没有 Autoload 的情况下直接调用它们。
##
## 注意：本脚本是 @tool，但编辑器里不采集（Engine.is_editor_hint() 时 set_process(false)）。

signal event_captured(event: Dictionary)
signal capture_finished(pack: Dictionary)
signal degraded(level: int, reasons: PackedStringArray)
signal budget_exceeded(status: Dictionary)

const DEFAULT_DIR := "user://perf_blackbox/captures"
const DEFAULT_RING := 1800
const LEDGER_DIR := "user://perf_blackbox/ledger"
const BUDGET_FILE := "user://perf_blackbox/budgets.json"

var _session: BBCaptureSession = null
var _last_pack: Dictionary = {}
var _emitted_events := 0
var _next_hitch := false
var _next_hitch_deadline_us := 0
var _last_level := 0
var _budget_warned := false
var _systems: Dictionary = {}
var _budgets: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000  # 最后跑：帧时间已包含本帧全部 work
	set_process(false)
	if Engine.is_editor_hint():
		return
	_budgets = _load_budgets()


# --- 采集生命周期 -----------------------------------------------------------

func start_capture(opts := {}) -> Dictionary:
	if Engine.is_editor_hint():
		push_warning("[Perf Blackbox] 编辑器内不采集；请在运行的项目里调用 BB.start_capture()")
		return _err("editor_hint")
	if not BBSettings.is_enabled():
		return _err("disabled_by_settings")
	if _session != null:
		return _err("already_capturing")
	var o := {
		"ring": int(opts.get("ring", BBSettings.ring_capacity())),
		"probe": String(opts.get("probe", BBSettings.probe_mode())),
		"shots": bool(opts.get("shots", BBSettings.capture_shots())),
	}
	for k in opts:
		if not o.has(k):
			o[k] = opts[k]
	_session = BBCaptureSession.new()
	_session.start(get_tree(), o)
	_emitted_events = 0
	_last_level = 0
	_budget_warned = false
	_next_hitch = false
	set_process(true)
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"ok": true,
		"started_frame": _session.frame,
		"ring": _session.sampler.ring.capacity,
		"probe": o["probe"],
	}


func is_capturing() -> bool:
	return _session != null and _session.is_capturing()


## 停止并返回内存里的包（不写盘；写盘用 export_pack）
func stop_capture() -> Dictionary:
	if _session == null:
		return _err("not_capturing")
	_next_hitch = false
	var pack := _session.stop()
	_last_pack = pack
	_session = null
	set_process(false)
	var status := evaluate_budget(pack)
	pack["budget_status"] = status
	_last_pack = pack
	capture_finished.emit(pack)
	if String(status.get("state", "")) in ["fail", "warn"]:
		budget_exceeded.emit(status)
	return pack


## 录到下一次掉帧就自动停（M1 的主用法：玩家/测试跑一遍，回来就有包）
func capture_next_hitch(timeout_s := 30.0) -> Dictionary:
	if _session == null:
		var r := start_capture()
		if not bool(r.get("ok", false)):
			return r
	var before := _session.events.size()
	_next_hitch = true
	_next_hitch_deadline_us = Time.get_ticks_usec() + int(timeout_s * 1000000.0)
	return {"schema_version": BBSchema.SCHEMA_VERSION, "ok": true, "timeout_s": timeout_s, "events_before": before}


func mark(label: String) -> bool:
	if _session == null:
		push_warning("[Perf Blackbox] 没在采集，标记被忽略")
		return false
	_session.mark(label)
	return true


func is_waiting_for_hitch() -> bool:
	return _next_hitch


# --- 读取 -------------------------------------------------------------------

func events() -> Array[Dictionary]:
	if _session != null:
		return _session.event_summary()
	return _summary_from_pack(_last_pack)


func get_event(id: String) -> Dictionary:
	if _session != null:
		return _session.get_event(id)
	for ev in _last_pack.get("events", []):
		if String(ev.get("id", "")) == id:
			var out: Dictionary = ev.duplicate(true)
			out["delta"] = _last_pack.get("deltas", {}).get(id, {})
			out["schema_version"] = BBSchema.SCHEMA_VERSION
			return out
	return {}


func last_pack() -> Dictionary:
	return _last_pack


func last_pack_info() -> Dictionary:
	if _last_pack.is_empty():
		return _err("no_pack")
	var m: Dictionary = _last_pack.get("manifest", {})
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"frames": int(_last_pack.get("frames", 0)),
		"start_frame": int(_last_pack.get("start_frame", 0)),
		"events": _last_pack.get("events", []).size(),
		"elapsed_ms": m.get("capture", {}).get("elapsed_ms", 0.0),
		"degradations": m.get("capture", {}).get("degradations", []),
	}


# --- 出口 -------------------------------------------------------------------

func export_pack(pack := {}, path := "", format := "bhx") -> Dictionary:
	var p: Dictionary = pack if not pack.is_empty() else _last_pack
	if p.is_empty():
		return _err("no_pack")
	var fmt := format
	var target := path
	if target == "":
		target = _default_path(fmt)
	_ensure_dir(target.get_base_dir())
	match fmt:
		"bhx":
			var w := BBPackWriter.write(target, p)
			BBSettings.rotate_storage(DEFAULT_DIR)
			return w
		"md":
			return _write_text(target, BBReport.build(p), fmt)
		"prompt":
			return _write_text(target, BBPromptPack.build(p), fmt)
		"json":
			return _write_text(target, JSON.stringify(BBSchema.sanitize(p), "  "), fmt)
		_:
			return _err("bad_format: %s" % fmt)


func export_last(format := "bhx") -> Dictionary:
	return export_pack(_last_pack, "", format)


func capture_dir() -> String:
	return DEFAULT_DIR


# --- D1 预算与基线 -----------------------------------------------------------

## 给一张图声明帧预算。不声明也能用（那时只做相对基线的漂移判定）
func set_budget(scene: String, p95_ms: float, max_ms := 0.0) -> Dictionary:
	var key := scene if scene != "" else "<default>"
	_budgets[key] = {"p95": p95_ms, "max": max_ms}
	_save_budgets()
	return {"schema_version": BBSchema.SCHEMA_VERSION, "ok": true, "scene": key, "budget": _budgets[key]}


func get_budget(scene := "") -> Dictionary:
	var key := scene if scene != "" else "<default>"
	if _budgets.has(key):
		return _budgets[key]
	if _budgets.has("<default>"):
		return _budgets["<default>"]
	var fallback := BBSettings.budget_default_p95()
	return {"p95": fallback, "max": 0.0, "default": true} if fallback > 0.0 else {}


## 评估一份包（默认用最近一次）：PASS / WARN / FAIL / insufficient / no_budget
func evaluate_budget(pack := {}) -> Dictionary:
	var p: Dictionary = pack if not pack.is_empty() else _last_pack
	if p.is_empty():
		return _err("no_pack")
	var summary := BBBudget.summarize(p)
	var scene := String(summary.get("scene", ""))
	var budget := get_budget(scene)
	var baseline := BBBudget.load_baseline(scene)
	return BBBudget.evaluate(summary, budget, baseline)


## 面板/CI 用的一行状态
func get_budget_status() -> Dictionary:
	var res := evaluate_budget()
	if not bool(res.get("ok", true)) or res.has("error"):
		return res
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"state": res.get("state", ""),
		"p95": res.get("p95", 0.0),
		"max": res.get("max", 0.0),
		"drift": res.get("drift", 0.0),
		"baseline_path": BBBudget.baseline_path(String(res.get("scene", ""))),
		"notes": res.get("notes", []),
		"budget": res.get("budget", {}),
	}


## 把这次的统计存成基线（写 res://，可随仓库提交）
func save_baseline(pack := {}, scene := "") -> Dictionary:
	var p: Dictionary = pack if not pack.is_empty() else _last_pack
	if p.is_empty():
		return _err("no_pack")
	return BBBudget.save_baseline(BBBudget.summarize(p), scene)


# --- D2 系统成本账本 ---------------------------------------------------------

## 注册一个可开关的「系统」：node / group / custom
## 例：BB.define_system({"name":"敌人AI","kind":"group","target":"enemies"})
func define_system(spec: Dictionary) -> Dictionary:
	var name := String(spec.get("name", ""))
	if name == "":
		return _err("system_needs_name")
	_systems[name] = spec.duplicate(true)
	return {"schema_version": BBSchema.SCHEMA_VERSION, "ok": true, "system": name, "spec": _systems[name]}


func list_systems() -> Array:
	var out := []
	for k in _systems:
		out.append({"name": k, "kind": String(_systems[k].get("kind", "node"))})
	return out


## 测量一个系统的开销：交错 A/B 多轮 + 配对差分 + bootstrap CI
## 必须 await：`var r = await BB.measure_system("敌人AI")`
func measure_system(name: String, opts := {}, spec := {}) -> Dictionary:
	var s: Dictionary = spec if not spec.is_empty() else _systems.get(name, {})
	if s.is_empty():
		return _err("unknown_system: %s" % name)
	s = s.duplicate(true)
	s["name"] = name
	if not BBSettings.is_enabled():
		return _err("disabled_by_settings")
	# 测量期间停掉自己的采集，避免自己的开销污染结果
	var was_capturing := _session != null
	if was_capturing:
		stop_capture()
	var res: Dictionary = await BBSystemMatrix.measure(get_tree(), s, opts)
	if was_capturing:
		start_capture()
	if not res.has("error"):
		_persist_ledger(name, res)
	return res


func _persist_ledger(name: String, res: Dictionary) -> void:
	_ensure_dir(LEDGER_DIR)
	var path := LEDGER_DIR.path_join(name.validate_filename() + ".json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(res, "  "))
	f.close()


func ledger_dir() -> String:
	return LEDGER_DIR


# --- C3 时间线 ---------------------------------------------------------------

## 导出一份自包含 HTML（双击即开，不依赖编辑器）
func export_timeline(pack := {}, path := "") -> Dictionary:
	var p: Dictionary = pack if not pack.is_empty() else _last_pack
	if p.is_empty():
		return _err("no_pack")
	var target := path
	if target == "":
		target = _default_path("html")
	_ensure_dir(target.get_base_dir())
	return _write_text(target, BBTimeline.build_html(p), "html")


# --- E1 静态渲染清单 ---------------------------------------------------------

## 导出一份「当前场景里有什么」的清单。
## source: Node（场景根）/ String（res:// 场景路径）/ null（编辑器里取正在编辑的场景，运行时取当前场景）
func render_manifest(source = null, opts := {}) -> Dictionary:
	if source is Node:
		return BBRenderManifest.build(source, opts)
	if source is String or source is StringName:
		return BBRenderManifest.build_from_scene_path(String(source), opts)
	var root: Node = null
	if Engine.is_editor_hint():
		root = EditorInterface.get_edited_scene_root()
	else:
		var tree := get_tree()
		root = tree.current_scene if tree != null else null
	if root == null:
		return BBRenderManifest.build(null, opts)
	return BBRenderManifest.build(root, opts)


## 把清单写成人看的 Markdown（也顺便返回结构化结果）。
func export_render_manifest(source = null, path := "", opts := {}) -> Dictionary:
	var manifest := render_manifest(source, opts)
	if manifest.has("error"):
		return manifest
	var target := path
	if target == "":
		target = _default_path("md", "manifest")
	_ensure_dir(target.get_base_dir())
	var res := _write_text(target, String(manifest.get("markdown", "")), "md")
	if res.has("error"):
		return res
	var out := manifest.duplicate(true)
	out["path"] = res.get("path", target)
	return out


# --- E2 静态 × 实测关联 -------------------------------------------------------

## 把 .bhx 的事件证据和静态清单对上，产出「可验证的假设 + 怎么验」。
func correlate(pack := {}, manifest := {}) -> Dictionary:
	var p: Dictionary = pack if not pack.is_empty() else _last_pack
	return BBCorrelate.correlate(p, manifest)


## 单条假设的实验方案（供面板/CLI/提示词直接展示）。
func plan_experiment(kind: String, key: String, added := 0) -> Dictionary:
	return BBCorrelate.plan_experiment(kind, key, added)


# --- D4 接入向导 + 自动插桩 ---------------------------------------------------

## 扫项目，给出「先把什么变成可测对象、给哪些函数装探针」的清单（不修改文件）。
func wizard_scan(opts := {}) -> Dictionary:
	return BBWizard.scan(opts)


## 只看当前场景（或指定场景）的接入建议。
func wizard_for_scene(scene_path := "") -> Dictionary:
	var path := scene_path
	if path == "":
		var root: Node = null
		if Engine.is_editor_hint():
			root = EditorInterface.get_edited_scene_root()
		else:
			var tree := get_tree()
			root = tree.current_scene if tree != null else null
		if root != null:
			path = root.scene_file_path
	if path == "":
		return {"schema_version": BBSchema.SCHEMA_VERSION, "kind": "onboarding", "error": "没有可用的场景"}
	return BBWizard.suggest_for_scene(path)


## 列出某脚本里可插桩的函数（只读）。
func probe_targets(script_path: String) -> Array[Dictionary]:
	return BBInstrumentation.suggest_targets(script_path)


## 给脚本插入口探针（会备份 + 解析校验失败自动放弃）。dry_run=true 只看预览。
func instrument_script(script_path: String, opts := {}) -> Dictionary:
	return BBInstrumentation.instrument_script(script_path, opts)


## 回滚插桩（用 .bak 恢复）。
func revert_instrumentation(script_path: String) -> Dictionary:
	return BBInstrumentation.revert_script(script_path)


# --- D3 跨提交回归 -----------------------------------------------------------

## a/b 可以是 pack 字典，也可以是 .bhx 路径。
func regression(a, b, opts := {}) -> Dictionary:
	var pa := _as_pack(a)
	var pb := _as_pack(b)
	if pa.is_empty() or pb.is_empty():
		return _err("regression_needs_two_packs")
	return BBRegression.compare(pa, pb, opts)


## 生成回归 Markdown 并落盘。
func export_regression(a, b, path := "", opts := {}) -> Dictionary:
	var res := regression(a, b, opts)
	if res.has("error"):
		return res
	var target := path
	if target == "":
		target = _default_path("md", "regression")
	_ensure_dir(target.get_base_dir())
	var written := _write_text(target, BBRegression.build_md(res, opts), "md")
	if written.has("error"):
		return written
	var out := res.duplicate(true)
	out["path"] = written.get("path", target)
	return out


func _as_pack(v) -> Dictionary:
	if v is Dictionary:
		return v
	if v is String or v is StringName:
		var path := String(v)
		if path == "":
			return {}
		var read := BBPackReader.read(path)
		if read.is_empty() or read.has("error"):
			return {}
		return read
	return {}


# --- 对比（D3 回归的最小内核；正式报告在 artifact 层）-------------------------

func compare(baseline: Dictionary, current: Dictionary) -> Dictionary:
	if baseline.is_empty() or current.is_empty():
		return _err("compare_needs_two_packs")
	var b_med := _median_of(baseline, "frame_ms")
	var c_med := _median_of(current, "frame_ms")
	var b_p95 := _p95_of(baseline, "frame_ms")
	var c_p95 := _p95_of(current, "frame_ms")
	var noise := BBStats.noise_floor(b_med, 0.05, 0.001)
	var column_deltas := {}
	for col_name in BBSchema.COLUMNS:
		var bv := _median_of(baseline, col_name)
		var cv := _median_of(current, col_name)
		if bv < 0.0 and cv < 0.0:
			continue
		column_deltas[col_name] = {"baseline": bv, "current": cv, "delta": cv - bv}
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"baseline": {"median_ms": b_med, "p95_ms": b_p95, "events": baseline.get("events", []).size()},
		"current": {"median_ms": c_med, "p95_ms": c_p95, "events": current.get("events", []).size()},
		"delta_median_ms": c_med - b_med,
		"delta_p95_ms": c_p95 - b_p95,
		"noise_floor_ms": noise,
		"verdict": _verdict(c_med - b_med, noise),
		"columns": column_deltas,
	}


func _verdict(delta: float, noise: float) -> String:
	if delta > noise:
		return "slower"
	if delta < -noise:
		return "faster"
	return "unchanged"


# --- 每帧 -------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _session == null:
		return
	_session.on_frame()

	var evs: Array[Dictionary] = _session.events
	while _emitted_events < evs.size():
		event_captured.emit(evs[_emitted_events])
		_emitted_events += 1

	if _session.guard != null and _session.guard.level != _last_level:
		_last_level = _session.guard.level
		degraded.emit(_last_level, _session.guard.degradations)
	if not _budget_warned and _session.guard != null and _session.guard.level > 0:
		_budget_warned = true
		budget_exceeded.emit(_session.guard.state())

	if not _next_hitch:
		return
	var got_event := _emitted_events > 0
	var timed_out := Time.get_ticks_usec() >= _next_hitch_deadline_us
	if got_event or timed_out:
		stop_capture()


# --- 内部 -------------------------------------------------------------------

func _default_path(fmt: String, kind := "") -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var ext := "md"
	if fmt in ["bhx", "json", "html"]:
		ext = fmt
	var label := kind if kind != "" else _tag()
	return "%s/%s_%s.%s" % [DEFAULT_DIR, stamp, label, ext]


func _load_budgets() -> Dictionary:
	if not FileAccess.file_exists(BUDGET_FILE):
		return {}
	var f := FileAccess.open(BUDGET_FILE, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _save_budgets() -> void:
	_ensure_dir(BUDGET_FILE.get_base_dir())
	var f := FileAccess.open(BUDGET_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_budgets, "  "))
	f.close()


func _tag() -> String:
	if _last_pack.is_empty():
		return "capture"
	var n: int = _last_pack.get("events", []).size()
	return "hitch" if n > 0 else "baseline"


func _ensure_dir(dir_path: String) -> void:
	if dir_path == "" or DirAccess.dir_exists_absolute(dir_path):
		return
	DirAccess.make_dir_recursive_absolute(dir_path)


func _write_text(path: String, text: String, fmt: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("write_failed: %s" % path)
	f.store_string(text)
	f.close()
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"ok": true,
		"format": fmt,
		"path": path,
		"bytes": text.to_utf8_buffer().size(),
	}


func _summary_from_pack(pack: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var deltas: Dictionary = pack.get("deltas", {})
	for ev in pack.get("events", []):
		var d: Dictionary = deltas.get(ev.get("id", ""), {})
		out.append({
			"id": ev.get("id", ""),
			"peak_frame": ev.get("peak_frame", -1),
			"peak_ms": ev.get("peak_ms", 0.0),
			"baseline_ms": ev.get("baseline_ms", 0.0),
			"ratio": ev.get("ratio", 0.0),
			"severity": ev.get("severity", ""),
			"tags": ev.get("tags", []),
			"bookmark": ev.get("bookmark", null),
			"root_cause": d.get("root_cause", "inconclusive"),
			"confidence": ev.get("confidence", 0.0),
		})
	return out


func _median_of(pack: Dictionary, col: String) -> float:
	var data: Dictionary = pack.get("data", {})
	if not data.has(col):
		return BBSchema.UNAVAILABLE
	var clean := PackedFloat64Array()
	for v in data[col]:
		if v >= 0.0:
			clean.append(v)
	if clean.is_empty():
		return BBSchema.UNAVAILABLE
	return BBStats.median(clean)


func _p95_of(pack: Dictionary, col: String) -> float:
	var data: Dictionary = pack.get("data", {})
	if not data.has(col):
		return BBSchema.UNAVAILABLE
	var clean := PackedFloat64Array()
	for v in data[col]:
		if v >= 0.0:
			clean.append(v)
	if clean.is_empty():
		return BBSchema.UNAVAILABLE
	return BBStats.percentile(clean, 0.95)


func _err(code: String) -> Dictionary:
	return {"schema_version": BBSchema.SCHEMA_VERSION, "ok": false, "error": code}

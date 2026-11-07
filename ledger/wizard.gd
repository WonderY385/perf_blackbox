@tool
class_name BBWizard
extends RefCounted
## D4 接入向导：把一个陌生项目快速变成「可测量」的状态。
##
## 它只做三件机械的事（不做业务判断）：
## 1. 扫场景，把根节点的直接子节点当成「系统候选」，生成可直接喂给 BB.define_system() 的 spec
## 2. 扫脚本，挑出入口函数，给出 `BBProbe.count()` 的插桩建议（真正改文件要显式调用
##    BBInstrumentation.instrument_script()，向导本身不写代码）
## 3. 把上面两件事排成一份有顺序的清单（先测什么、再测什么）

const SKIP_DIRS := ["res://addons", "res://.godot", "res://.git"]
const MAX_NODE_CANDIDATES := 24
const MAX_SCRIPT_CANDIDATES := 16


## 扫描项目，返回建议（不修改任何文件）。
static func scan(opts := {}) -> Dictionary:
	var max_scenes := int(opts.get("max_scenes", 12))
	var max_scripts := int(opts.get("max_scripts", MAX_SCRIPT_CANDIDATES))
	var scene_paths := _find_files("tscn", max_scenes, opts.get("root", "res://"))
	var script_paths := _find_files("gd", max_scripts, opts.get("root", "res://"))
	var systems: Array[Dictionary] = []
	var scene_notes: Array[String] = []
	for sp in scene_paths:
		var spec := _system_spec_from_scene(sp)
		if spec.is_empty():
			continue
		systems.append(spec)
		if spec.has("group"):
			scene_notes.append("%s：发现可当系统组的候选 %s" % [sp, String(spec["group"])])
	var probes: Array[Dictionary] = []
	for sc in script_paths:
		var targets := BBInstrumentation.suggest_targets(sc)
		if targets.is_empty():
			continue
		var entry: Array = []
		for t in targets:
			if bool(t.get("entry", false)) and not bool(t.get("already", false)):
				entry.append(t)
		if entry.is_empty():
			continue
		probes.append({"script": sc, "targets": entry.slice(0, 3)})
	var result := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "onboarding",
		"scenes_scanned": scene_paths.size(),
		"scripts_scanned": script_paths.size(),
		"systems": systems.slice(0, MAX_NODE_CANDIDATES),
		"probes": probes,
		"notes": scene_notes,
	}
	result["markdown"] = build_markdown(result)
	return result


## 单场景版（面板里对当前场景点一下就够用）。
static func suggest_for_scene(scene_path: String) -> Dictionary:
	var spec := _system_spec_from_scene(scene_path)
	if spec.is_empty():
		return {"schema_version": BBSchema.SCHEMA_VERSION, "kind": "onboarding", "error": "无法读取场景：%s" % scene_path}
	var probes: Array[Dictionary] = []
	for sc in _find_files("gd", MAX_SCRIPT_CANDIDATES, "res://"):
		var targets := BBInstrumentation.suggest_targets(sc)
		for t in targets:
			if bool(t.get("entry", false)) and not bool(t.get("already", false)):
				probes.append({"script": sc, "targets": [t]})
				break
		if probes.size() >= 6:
			break
	var res := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "onboarding",
		"systems": [spec],
		"probes": probes,
		"notes": [],
	}
	res["markdown"] = build_markdown(res)
	return res


static func _system_spec_from_scene(scene_path: String) -> Dictionary:
	var ps := load(scene_path)
	if ps == null or not (ps is PackedScene):
		return {}
	var inst := (ps as PackedScene).instantiate()
	if inst == null:
		return {}
	var children: Array[String] = []
	for c in inst.get_children():
		children.append(String(c.name))
	inst.free()
	if children.is_empty():
		return {"scene": scene_path, "systems": [], "error": "根节点没有子节点"}
	var base := scene_path.get_file().get_basename()
	return {
		"scene": scene_path,
		"systems": children.slice(0, 8),
		"template": {
			"kind": "node",
			"target": "/root/%s/%s" % [base, children[0]],
		},
		"hint": "把 target 换成你想量成本的子节点（也可以用 kind:\"group\" + 组名）",
	}


static func build_markdown(res: Dictionary) -> String:
	var lines: Array[String] = ["# 接入向导（D4）", ""]
	if res.has("error"):
		lines.append("扫描失败：%s" % String(res["error"]))
		return "\n".join(lines)
	lines.append("扫了 %d 个场景 / %d 个脚本。" % [int(res.get("scenes_scanned", 0)), int(res.get("scripts_scanned", 0))])
	lines.append("")
	lines.append("## 第 1 步：先确认能采到包")
	lines.append("")
	lines.append("```gdscript")
	lines.append("# 在游戏的入口处（或编辑器里对运行中的游戏用 game_eval）")
	lines.append("BB.start_capture({\"ring\": 1800, \"probe\": \"count\"})")
	lines.append("# 玩 30 秒，或直接")
	lines.append("BB.capture_next_hitch(60.0)")
	lines.append("var pack: Dictionary = BB.stop_capture()")
	lines.append("print(pack.events.size(), \" 个事件\")")
	lines.append("```")
	lines.append("")
	var systems: Array = res.get("systems", [])
	if not systems.is_empty():
		lines.append("## 第 2 步：把系统登记成可测对象")
		lines.append("")
		for s in systems:
			var d: Dictionary = s
			if d.has("error"):
				continue
			if d.has("systems"):
				lines.append("### `%s`" % String(d.get("scene", "")))
				lines.append("")
				lines.append("候选系统（根节点的直接子节点）：%s" % ", ".join(PackedStringArray(d.get("systems", []))))
				lines.append("")
				var tmpl: Dictionary = d.get("template", {})
				lines.append("```gdscript")
				lines.append("BB.define_system({\"name\": \"%s\", \"kind\": \"node\", \"target\": \"%s\"})" % [
					String(d.get("scene", "")).get_file().get_basename(),
					String(tmpl.get("target", ""))])
				lines.append("var res: Dictionary = await BB.measure_system(\"%s\")" % String(d.get("scene", "")).get_file().get_basename())
				lines.append("print(res.delta_ms, \"ms  CI \", res.ci_low_ms, \"~\", res.ci_high_ms)")
				lines.append("```")
				lines.append("")
	var probes: Array = res.get("probes", [])
	if not probes.is_empty():
		lines.append("## 第 3 步：给热点函数装探针（B1）")
		lines.append("")
		lines.append("下面是入口函数候选，**向导不会替你改代码**：确认后用 `BBInstrumentation.instrument_script()` 执行，")
		lines.append("或手工在函数体第一行加一行 `BBProbe.count(\"类名::函数名\")`。改坏了用 `BBInstrumentation.revert_script()` 回滚。")
		lines.append("")
		for p in probes:
			var d: Dictionary = p
			var names: Array[String] = []
			for t in d.get("targets", []):
				names.append(String((t as Dictionary).get("id", "")))
			lines.append("- `%s` → %s" % [String(d.get("script", "")), "、".join(PackedStringArray(names))])
		lines.append("")
	else:
		lines.append("## 第 3 步：没有找到可插桩的入口函数")
		lines.append("")
		lines.append("说明脚本层暂时不是候选主因；先看 B2/B3 的证据（实体增量、计数差分）与 D2 系统账本。")
		lines.append("")
	lines.append("## 之后做什么")
	lines.append("")
	lines.append("1. 用 `BB.set_budget()` 定目标，`BB.save_baseline()` 存基线，之后每次采集自动判 PASS/WARN/FAIL")
	lines.append("2. 改一版代码后 `BB.export_regression(旧包, 新包)`，或 `bb_cli --regress=` 接 CI")
	lines.append("3. 掉帧事件里如果出现「新冒出来的实体」，用 `BB.correlate(pack, BB.render_manifest())` 找静态依据")
	lines.append("")
	return "\n".join(lines)


static func _find_files(ext: String, limit: int, root := "res://") -> Array[String]:
	var out: Array[String] = []
	var queue: Array[String] = [root]
	while not queue.is_empty() and out.size() < limit:
		var dir := queue.pop_front()
		if _skip(dir):
			continue
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for f in d.get_files():
			if f.get_extension().to_lower() == ext:
				out.append(dir.path_join(f))
				if out.size() >= limit:
					break
		for sub in d.get_directories():
			var path: String = dir.path_join(sub)
			if not _skip(path):
				queue.append(path)
	out.sort()
	return out


static func _skip(path: String) -> bool:
	var norm := path.replace("\\", "/")
	for s in SKIP_DIRS:
		if norm.begins_with(s):
			return true
	return false

@tool
extends SceneTree
## F3 无头 CLI：把 .bhx 变成 CI 能用的东西。
##
## 用法（注意 `--` 之后才是本工具的参数）：
##   godot --headless --path <项目> --script res://addons/perf_blackbox/tools/bb_cli.gd -- \
##       --regress=old.bhx,new.bhx --out=regress.md
##
## 子命令（一次可给多个，按顺序执行，任一失败则退出码非 0）：
##   --list-packs[=<dir>]                 列出采集包
##   --inspect=<pack>                     JSON 摘要打到 stdout
##   --report=<pack> [--out=file.md]      生成人读报告
##   --prompt=<pack> [--out=file.md] [--tokens=N]  生成 AI 提示词包
##   --timeline=<pack> [--out=file.html]  生成自包含 HTML 时间线
##   --manifest=<res://scene.tscn> [--out=file.md] 静态渲染清单
##   --correlate=<pack>,<res://scene>  [--out=file.md] 静态 × 实测关联
##   --regress=<a.bhx>,<b.bhx> [--out=file.md]   跨提交回归（有退化则退出码 2）
##   --budget-gate=<pack>                 预算/基线门禁（fail/warn 则退出码 2）
##
## 退出码：0 = 通过；2 = 发现退化/超预算；1 = 参数或读取错误。

const DEFAULT_OUT_DIR := "user://perf_blackbox/reports"

var _exit_code := 0
var _out_dir := ""


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_usage()
		quit(1)
		return
	_out_dir = ProjectSettings.globalize_path(DEFAULT_OUT_DIR)
	DirAccess.make_dir_recursive_absolute(_out_dir)
	for a in args:
		if not a.begins_with("--"):
			continue
		var key := a.substr(2)
		var value := ""
		var eq := key.find("=")
		if eq >= 0:
			value = key.substr(eq + 1)
			key = key.substr(0, eq)
		_dispatch(key, value)
		if _exit_code != 0:
			break
	quit(_exit_code)


func _dispatch(key: String, value: String) -> void:
	# 全局修饰参数：不单独作为命令处理
	if key in ["out", "tokens", "dir"]:
		return
	match key:
		"list-packs":
			_cmd_list_packs(value)
		"inspect":
			_cmd_inspect(value)
		"report":
			_cmd_report(value)
		"prompt":
			_cmd_prompt(value)
		"timeline":
			_cmd_timeline(value)
		"manifest":
			_cmd_manifest(value)
		"correlate":
			_cmd_correlate(value)
		"regress":
			_cmd_regress(value)
		"budget-gate":
			_cmd_budget_gate(value)
		"help", "h":
			_usage()
		_:
			print("[bb_cli] 未知参数 --%s" % key)
			_usage()
			_exit_code = 1


func _cmd_list_packs(dir := "") -> void:
	var base := dir if dir != "" else BBPackReader.capture_dir()
	var packs := BBPackReader.list_captures(base)
	if packs.is_empty():
		print("[bb_cli] 没有采集包：%s" % base)
		return
	for p in packs:
		var info := BBPackReader.read_manifest(p)
		print("%s  events=%d  frames=%d  size=%d" % [
			p.get_file(),
			int(info.get("event_count", 0)),
			int((info.get("capture", {}) as Dictionary).get("frames", 0)),
			_file_size(p)])


func _cmd_inspect(path: String) -> void:
	var pack := _load(path)
	if pack.is_empty():
		return
	var summary := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"file": path,
		"frames": int(pack.get("frames", 0)),
		"events": (pack.get("events", []) as Array).size(),
		"event_list": _event_rows(pack),
		"budget": BBBudget.evaluate(BBBudget.summarize(pack), {}, {}),
	}
	print(JSON.stringify(summary, "  "))


func _cmd_report(path: String) -> void:
	var pack := _load(path)
	if pack.is_empty():
		return
	_write_out(path, "report.md", BBReport.build(pack, {"lang": "zh"}), "--report")


func _cmd_prompt(path: String) -> void:
	var pack := _load(path)
	if pack.is_empty():
		return
	var tokens := int(_arg_value("tokens", "2000"))
	_write_out(path, "prompt.md", BBPromptPack.build(pack, {"max_tokens": tokens}), "--prompt")


func _cmd_timeline(path: String) -> void:
	var pack := _load(path)
	if pack.is_empty():
		return
	_write_out(path, "timeline.html", BBTimeline.build_html(pack), "--timeline")


func _cmd_manifest(path: String) -> void:
	if path == "":
		print("[bb_cli] --manifest 需要场景路径")
		_exit_code = 1
		return
	var manifest := BBRenderManifest.build_from_scene_path(path)
	if manifest.has("error"):
		print("[bb_cli] %s" % String(manifest.get("error", "")))
		_exit_code = 1
		return
	var text := String(manifest.get("markdown", ""))
	print(text)
	var out := _out_path_for(path, "manifest.md")
	_save(out, text)
	print("[bb_cli] 已写 %s" % out)


func _cmd_correlate(value: String) -> void:
	var parts := value.split(",", false, 1)
	if parts.size() < 2:
		print("[bb_cli] --correlate=<pack.bhx>,<res://scene.tscn>")
		_exit_code = 1
		return
	var pack := _load(parts[0])
	if pack.is_empty():
		return
	var manifest := BBRenderManifest.build_from_scene_path(parts[1])
	if manifest.has("error"):
		print("[bb_cli] %s" % String(manifest.get("error", "")))
		_exit_code = 1
		return
	var res := BBCorrelate.correlate(pack, manifest)
	var text := String(res.get("markdown", ""))
	print(text)
	var out := _out_path_for(parts[0], "correlate.md")
	_save(out, text)
	print("[bb_cli] 已写 %s" % out)


func _cmd_regress(value: String) -> void:
	var parts := value.split(",", false, 1)
	if parts.size() < 2:
		print("[bb_cli] --regress=<a.bhx>,<b.bhx>")
		_exit_code = 1
		return
	var a := _load(parts[0])
	var b := _load(parts[1])
	if a.is_empty() or b.is_empty():
		return
	var res := BBRegression.compare(a, b, {})
	var md := BBRegression.build_md(res, {"baseline_label": parts[0].get_file(), "current_label": parts[1].get_file()})
	print(md)
	var out := _out_path_for(parts[1], "regression.md")
	_save(out, md)
	print("[bb_cli] verdict=%s exit=%d 已写 %s" % [
		String(res.get("verdict", "")), int(res.get("exit_code", 0)), out])
	if int(res.get("exit_code", 0)) != BBRegression.PASS_EXIT:
		_exit_code = int(res.get("exit_code", BBRegression.REGRESSION_EXIT))


func _cmd_budget_gate(path: String) -> void:
	var pack := _load(path)
	if pack.is_empty():
		return
	var summary := BBBudget.summarize(pack)
	var scene := String(summary.get("scene", ""))
	var budget := BBBudget.load_budget(scene)
	var baseline := BBBudget.load_baseline(scene)
	var res := BBBudget.evaluate(summary, budget, baseline)
	print("[bb_cli] budget scene=%s state=%s p95=%.2fms max=%.2fms drift=%s" % [
		scene, String(res.get("state", "")), float(summary.get("p95", -1.0)),
		float(summary.get("max", -1.0)), str(res.get("drift", -1.0))])
	if String(res.get("state", "")) in ["fail", "warn"]:
		_exit_code = BBRegression.REGRESSION_EXIT


func _load(path: String) -> Dictionary:
	if path == "":
		print("[bb_cli] 缺少 .bhx 路径")
		_exit_code = 1
		return {}
	if not FileAccess.file_exists(path):
		print("[bb_cli] 文件不存在：%s" % path)
		_exit_code = 1
		return {}
	var pack := BBPackReader.read(path)
	if pack.has("error"):
		print("[bb_cli] 读取失败：%s" % String(pack.get("error", "")))
		_exit_code = 1
		return {}
	return pack


func _event_rows(pack: Dictionary) -> Array:
	var rows: Array = []
	for ev in pack.get("events", []):
		var e: Dictionary = ev
		rows.append({
			"id": e.get("id", ""),
			"peak_frame": e.get("peak_frame", -1),
			"peak_ms": e.get("peak_ms", 0.0),
			"baseline_ms": e.get("baseline_ms", 0.0),
			"ratio": e.get("ratio", 0.0),
			"severity": e.get("severity", ""),
		})
	return rows


func _scene_key(pack: Dictionary) -> String:
	var snap: Dictionary = pack.get("scene_snapshot", {})
	var scene := String(snap.get("scene_path", ""))
	if scene == "":
		scene = String(snap.get("scene", ""))
	return scene


func _arg_value(key: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % key):
			return a.substr(key.length() + 3)
	return fallback


func _write_out(pack_path: String, suffix: String, text: String, flag: String) -> void:
	var out := _arg_value("out", "")
	if out == "":
		out = _out_path_for(pack_path, suffix)
	print(text)
	_save(out, text)
	print("[bb_cli] %s 已写 %s" % [flag, out])


func _out_path_for(src: String, suffix: String) -> String:
	var explicit := _arg_value("out", "")
	if explicit != "":
		return explicit
	var base := src.get_file().get_basename()
	if base == "":
		base = "bb"
	return "%s/%s_%s" % [_out_dir, base, suffix]


func _save(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("[bb_cli] 无法写入：%s" % path)
		_exit_code = 1
		return
	f.store_string(text)
	f.close()


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


func _usage() -> void:
	print("""[Perf Blackbox CLI]
godot --headless --path <项目> --script res://addons/perf_blackbox/tools/bb_cli.gd -- <命令>

  --list-packs[=<dir>]
  --inspect=<pack.bhx>
  --report=<pack.bhx> [--out=file.md]
  --prompt=<pack.bhx> [--out=file.md] [--tokens=2000]
  --timeline=<pack.bhx> [--out=file.html]
  --manifest=<res://scene.tscn> [--out=file.md]
  --correlate=<pack.bhx>,<res://scene.tscn> [--out=file.md]
  --regress=<a.bhx>,<b.bhx> [--out=file.md]
  --budget-gate=<pack.bhx>

退出码：0 通过 / 2 退化或超预算 / 1 用法错误""")

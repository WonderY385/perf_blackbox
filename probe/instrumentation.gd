@tool
class_name BBInstrumentation
extends RefCounted
## 自动插桩（探针）。B1 主链路是「入口级函数插入 BBProbe.count()」，
## 手写太琐碎，这里做半自动：只插入口函数、可回滚、改完立刻用 GDScript 重新解析校验。
##
## 刻意保守：
## - 只处理 `func` 定义行（签名必须以 `)` 或 `-> 类型:` 结尾，单行函数跳过）
## - 跳过 `_init` / `_static_init`（构造期不应有探针）
## - 已经有 BBProbe 的脚本不动
## - C# 不支持（GDScript 专用），README 里写明
## - 语法校验失败自动回滚

const PROBE_CALL := "BBProbe.count(\"%s\")"
const SKIP_NAMES := ["_init", "_static_init", "_notification"]
const ENTRY_PREFIXES := ["_ready", "_process", "_physics_process", "_input", "_unhandled_input", "_integrate_forces"]


## 列出可插桩的函数（面板/向导展示用）。
static func suggest_targets(script_path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var text := _read(script_path)
	if text == "":
		return out
	var cls := _class_name_of(text, script_path)
	var lines := text.split("\n")
	for i in lines.size():
		var f := _parse_func_line(lines[i])
		if f.is_empty():
			continue
		var fname := String(f["name"])
		if fname in SKIP_NAMES:
			continue
		out.append({
			"name": fname,
			"id": "%s::%s" % [cls, fname],
			"line": i + 1,
			"entry": fname in ENTRY_PREFIXES or fname.begins_with("tick") or fname.begins_with("update"),
			"already": text.contains("BBProbe.count(\"%s::%s\")" % [cls, fname]),
		})
	return out


## 给一个脚本插桩。opts: {"only_entry": true, "max_funcs": 12, "dry_run": false}
static func instrument_script(script_path: String, opts := {}) -> Dictionary:
	var only_entry := bool(opts.get("only_entry", true))
	var max_funcs := int(opts.get("max_funcs", 12))
	var dry_run := bool(opts.get("dry_run", false))
	var text := _read(script_path)
	if text == "":
		return {"ok": false, "error": "无法读取脚本：%s" % script_path}
	if not script_path.ends_with(".gd"):
		return {"ok": false, "error": "只支持 GDScript（C# 需手工插桩）"}
	if text.contains("BBProbe."):
		return {"ok": false, "error": "脚本里已有 BBProbe 调用，跳过以免重复插入"}
	var cls := _class_name_of(text, script_path)
	var lines := text.split("\n")
	var inserts: Array[Dictionary] = []
	for i in lines.size():
		var f := _parse_func_line(lines[i])
		if f.is_empty():
			continue
		var fname := String(f["name"])
		if fname in SKIP_NAMES:
			continue
		if only_entry and not (fname in ENTRY_PREFIXES or fname.begins_with("tick") or fname.begins_with("update")):
			continue
		# 找函数体第一行的缩进
		if i + 1 >= lines.size():
			continue
		var body := lines[i + 1]
		if body.strip_edges() == "":
			continue
		var body_indent := _indent_of(body)
		if _indent_of(lines[i]) >= body_indent:
			continue  # 单行函数 / 无体
		inserts.append({"line": i + 1, "indent": body_indent, "name": fname})
		if inserts.size() >= max_funcs:
			break
	if inserts.is_empty():
		return {"ok": false, "error": "没有找到可插桩的函数（可设 only_entry=false 放宽）"}

	var out_lines: Array[String] = []
	var cursor := 0
	var applied: Array[String] = []
	for ins in inserts:
		var idx := int(ins["line"])  # 在签名行之后插入
		while cursor <= idx:
			out_lines.append(lines[cursor])
			cursor += 1
		out_lines.append("%s%s" % [String(ins["indent"]), PROBE_CALL % ("%s::%s" % [cls, String(ins["name"])])])
		applied.append("%s::%s" % [cls, String(ins["name"])])
	while cursor < lines.size():
		out_lines.append(lines[cursor])
		cursor += 1
	var new_text := "\n".join(out_lines)

	var check := _validate(new_text)
	if not bool(check.get("ok", false)):
		return {"ok": false, "error": "插桩后解析失败，已放弃：%s" % String(check.get("error", "")), "applied": applied}
	if dry_run:
		return {"ok": true, "dry_run": true, "script": script_path, "functions": applied, "preview": new_text}

	var backup := script_path + ".bak"
	if not FileAccess.file_exists(backup):
		var b := FileAccess.open(backup, FileAccess.WRITE)
		if b != null:
			b.store_string(text)
			b.close()
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "无法写入脚本：%s" % script_path}
	f.store_string(new_text)
	f.close()
	return {"ok": true, "script": script_path, "functions": applied, "backup": backup, "bytes": new_text.length()}


## 回滚（用 .bak 覆盖回去）。
static func revert_script(script_path: String) -> Dictionary:
	var backup := script_path + ".bak"
	if not FileAccess.file_exists(backup):
		return {"ok": false, "error": "没有备份：%s" % backup}
	var b := FileAccess.open(backup, FileAccess.READ)
	if b == null:
		return {"ok": false, "error": "无法读取备份"}
	var text := b.get_as_text()
	b.close()
	var f := FileAccess.open(script_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "无法写入：%s" % script_path}
	f.store_string(text)
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
	return {"ok": true, "script": script_path, "restored_bytes": text.length()}


static func _parse_func_line(line: String) -> Dictionary:
	var stripped := line.strip_edges()
	if stripped.begins_with("#"):
		return {}
	if not (stripped.begins_with("func ") or stripped.begins_with("static func ") or stripped.begins_with("@warning_ignore") ):
		if not stripped.begins_with("func "):
			return {}
	if not stripped.ends_with(":"):
		return {}
	if stripped.begins_with("@warning_ignore"):
		return {}
	var open := stripped.find("(")
	if open < 0:
		return {}
	var head := stripped.substr(0, open)
	var parts := head.split(" ", false)
	if parts.is_empty():
		return {}
	var fname := String(parts[parts.size() - 1])
	if fname == "" or not fname.is_valid_identifier():
		return {}
	return {"name": fname}


static func _class_name_of(text: String, script_path: String) -> String:
	for line in text.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("class_name "):
			var rest := s.substr("class_name ".length()).strip_edges()
			var cut := rest.find(" ")
			return rest if cut < 0 else rest.substr(0, cut)
	return script_path.get_file().get_basename().to_pascal_case()


static func _indent_of(line: String) -> String:
	var out := ""
	for c in line:
		if c == "\t" or c == " ":
			out += c
		else:
			break
	return out


static func _validate(source: String) -> Dictionary:
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		return {"ok": false, "error": "parse error (%d)" % err}
	return {"ok": true}


static func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text

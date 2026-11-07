@tool
class_name BBPackReader
extends RefCounted
## C1 读取器：只认 schema_version <= 当前；未知字段忽略、缺失字段填默认，
## 永不因版本问题抛错（坏包/未来包都给结构化诊断而不是崩）。

const MAGIC := "BBF1"


static func capture_dir() -> String:
	return BBSchema.CAPTURE_DIR


## 列出采集目录下所有 .bhx（按文件名升序 = 按时间升序）
static func list_captures(dir := "") -> PackedStringArray:
	var base := dir if dir != "" else BBSchema.CAPTURE_DIR
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(base):
		return out
	for n in DirAccess.get_files_at(base):
		if n.get_extension().to_lower() == "bhx":
			out.append(base.path_join(n))
	out.sort()
	return out


static func read_manifest(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "无法打开 %s" % path}
	var out := _read_json(zip, "manifest.json")
	zip.close()
	if out.is_empty():
		return {"error": "缺少 manifest.json"}
	return out


static func read(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "无法打开 %s" % path}

	var warnings: Array[String] = []
	var manifest := _read_json(zip, "manifest.json")
	if manifest.is_empty():
		zip.close()
		return {"error": "缺少 manifest.json"}

	var schema := int(manifest.get("schema_version", 0))
	if schema > BBSchema.SCHEMA_VERSION:
		warnings.append("包 schema_version=%d 高于本插件支持的 %d，按兼容模式读取" % [schema, BBSchema.SCHEMA_VERSION])

	var pack := {
		"schema_version": schema,
		"manifest": manifest,
		"columns": PackedStringArray(manifest.get("capture", {}).get("columns", PackedStringArray())),
		"start_frame": int(manifest.get("capture", {}).get("start_frame", 0)),
		"frames": int(manifest.get("capture", {}).get("frames", 0)),
		"data": {},
		"events": [],
		"deltas": {},
		"scene_snapshot": {},
		"report_md": "",
		"prompt_md": "",
		"diagnostics": {"warnings": warnings},
	}

	if zip.file_exists("frames.bin"):
		var bin := zip.read_file("frames.bin")
		var parsed := _parse_frames_bin(bin)
		if parsed.has("error"):
			warnings.append(String(parsed["error"]))
		else:
			pack["data"] = parsed["data"]
			pack["frames"] = int(parsed["frames"])
			pack["columns"] = parsed["columns"]
	else:
		warnings.append("包内没有 frames.bin（summary 级导出或损坏）")

	var jsonl := _read_text(zip, "events.jsonl")
	for line in jsonl.split("\n", false):
		var text := line.strip_edges()
		if text == "":
			continue
		var parsed_line = JSON.parse_string(text)
		if parsed_line is Dictionary:
			pack["events"].append(parsed_line)

	var deltas = _read_json(zip, "deltas.json")
	if deltas is Dictionary:
		pack["deltas"] = deltas

	var snap = _read_json(zip, "scene_snapshot.json")
	if snap is Dictionary:
		pack["scene_snapshot"] = snap

	pack["report_md"] = _read_text(zip, "report.md")
	pack["prompt_md"] = _read_text(zip, "prompt.md")

	zip.close()
	return pack


static func _parse_frames_bin(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 12:
		return {"error": "frames.bin 过短"}
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	var magic := _take(buf, 4).get_string_from_ascii()
	if magic != MAGIC:
		return {"error": "frames.bin magic 不匹配：%s" % magic}
	var ncols := int(buf.get_u32())
	var nframes := int(buf.get_u32())
	var data := {}
	var columns := PackedStringArray()
	for _i in ncols:
		if buf.get_available_bytes() < 4:
			return {"error": "frames.bin 列头被截断"}
		var nlen := int(buf.get_u32())
		var name := _take(buf, nlen).get_string_from_utf8()
		var count := int(buf.get_u32())
		if buf.get_available_bytes() < count * 8:
			return {"error": "frames.bin 列 %s 数据被截断" % name}
		var raw := _take(buf, count * 8)
		data[name] = raw.to_float64_array()
		columns.append(name)
	return {"data": data, "frames": nframes, "columns": columns}


## StreamPeer.get_data() 返回 [error, PackedByteArray] 二元组，这里统一取字节
static func _take(buf: StreamPeerBuffer, n: int) -> PackedByteArray:
	if n <= 0:
		return PackedByteArray()
	var res: Array = buf.get_data(n)
	if res.size() < 2:
		return PackedByteArray()
	var bytes: PackedByteArray = res[1]
	if bytes.size() < n:
		push_warning("frames.bin 数据不足：期望 %d 字节，实际 %d" % [n, bytes.size()])
	return bytes


static func _read_json(zip: ZIPReader, inner: String) -> Dictionary:
	if not zip.file_exists(inner):
		return {}
	var text := zip.read_file(inner).get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


static func _read_text(zip: ZIPReader, inner: String) -> String:
	if not zip.file_exists(inner):
		return ""
	return zip.read_file(inner).get_string_from_utf8()

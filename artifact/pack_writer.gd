@tool
class_name BBPackWriter
extends RefCounted
## C1 打包器：把内存中的一次采集写成 .bhx（ZIP 容器）。
## 不依赖 BB 单例，可在 headless / 编辑器里直接调用（便于测试）。

const MAGIC := "BBF1"


static func write(path: String, pack_in: Dictionary, opts := {}) -> Dictionary:
	var detail := String(opts.get("detail", "full"))
	# F4：脱敏只在这里做一次（唯一写入入口），避免各处导出漏掉
	var pack: Dictionary = pack_in
	if bool(opts.get("strip_paths", BBSettings.strip_paths())):
		pack = BBSettings.strip(pack_in)
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return {"error": "无法创建目录 %s（err %d）" % [dir, mk]}

	var columns: PackedStringArray = pack.get("columns", PackedStringArray())
	var data: Dictionary = pack.get("data", {})
	var frame_count := int(pack.get("frames", 0))

	var files := {}
	if detail != "summary" and data.size() > 0:
		files["frames.bin"] = _build_frames_bin(columns, data, frame_count)

	var events: Array = pack.get("events", [])
	var jsonl := ""
	for ev in events:
		jsonl += JSON.stringify(BBSchema.sanitize(ev)) + "\n"
	files["events.jsonl"] = jsonl.to_utf8_buffer()
	files["deltas.json"] = JSON.stringify(BBSchema.sanitize(pack.get("deltas", {})), "  ").to_utf8_buffer()
	files["scene_snapshot.json"] = JSON.stringify(BBSchema.sanitize(pack.get("scene_snapshot", {})), "  ").to_utf8_buffer()
	files["report.md"] = BBReport.build(pack).to_utf8_buffer()
	files["prompt.md"] = BBPromptPack.build(pack).to_utf8_buffer()

	var manifest: Dictionary = pack.get("manifest", {}).duplicate(true)
	var file_meta: Array = []
	for file_name in files:
		var bytes: PackedByteArray = files[file_name]
		file_meta.append({"path": file_name, "sha256": _sha256(bytes), "bytes": bytes.size()})
	manifest["files"] = file_meta
	manifest["event_count"] = events.size()
	manifest["schema_version"] = int(pack.get("schema_version", BBSchema.SCHEMA_VERSION))
	var manifest_bytes := JSON.stringify(BBSchema.sanitize(manifest), "  ").to_utf8_buffer()

	var zip := ZIPPacker.new()
	var err := zip.open(path)
	if err != OK:
		return {"error": "ZIPPacker.open 失败：%s（err %d）" % [path, err]}
	_write_entry(zip, "manifest.json", manifest_bytes)
	for file_name in files:
		_write_entry(zip, file_name, files[file_name])
	zip.close()

	var total_bytes := 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		total_bytes = int(f.get_length())
		f.close()

	return {
		"schema_version": int(pack.get("schema_version", BBSchema.SCHEMA_VERSION)),
		"path": path,
		"bytes": total_bytes,
		"sha256": _sha256(manifest_bytes),
		"event_count": events.size(),
		"files": file_meta.map(func(m): return m["path"]),
	}


static func _write_entry(zip: ZIPPacker, inner: String, bytes: PackedByteArray) -> void:
	zip.start_file(inner, 420, 0)
	zip.write_file(bytes)
	zip.close_file()


static func _build_frames_bin(columns: PackedStringArray, data: Dictionary, frames: int) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_data(MAGIC.to_ascii_buffer())
	buf.put_u32(columns.size())
	buf.put_u32(frames)
	for col_name in columns:
		var name_bytes := String(col_name).to_utf8_buffer()
		buf.put_u32(name_bytes.size())
		buf.put_data(name_bytes)
		var col: PackedFloat64Array = data.get(col_name, PackedFloat64Array())
		buf.put_u32(col.size())
		buf.put_data(col.to_byte_array())
	return buf.data_array


static func _sha256(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

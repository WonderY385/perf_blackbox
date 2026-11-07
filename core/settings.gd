@tool
class_name BBSettings
extends RefCounted
## F4 设置、隐私与存储轮转。
##
## 设计原则：**默认不打扰**——所有键都有默认值，用户不动 Project Settings 也能跑。
## 脱敏只在一个地方做（写入 .bhx 之前），避免「这份导出忘了脱敏」的漏网。

const PREFIX := "perf_blackbox/"

const DEFAULTS := {
	"enabled": true,
	"ring_capacity": 1800,
	"probe_mode": "count",          # off | count | time
	"max_overhead_ms": 0.5,
	"budget_default_p95": 16.6,
	"capture_shots": false,
	"mcp_enabled": false,
	"strip_paths": true,
	"hash_project_name": false,
	"keep_captures": 50,
}

const PROBE_MODES := ["off", "count", "time"]


static func get_value(key: String, fallback = null) -> Variant:
	var setting_key := key if key.begins_with(PREFIX) else PREFIX + key
	var short := setting_key.substr(PREFIX.length())
	var def = DEFAULTS.get(short, fallback)
	if not ProjectSettings.has_setting(setting_key):
		return def
	return ProjectSettings.get_setting(setting_key)


static func is_enabled() -> bool:
	return bool(get_value("enabled", true))


static func ring_capacity() -> int:
	return maxi(60, int(get_value("ring_capacity", 1800)))


static func probe_mode() -> String:
	var m := String(get_value("probe_mode", "count"))
	return m if m in PROBE_MODES else "count"


static func max_overhead_ms() -> float:
	return maxf(0.05, float(get_value("max_overhead_ms", 0.5)))


static func budget_default_p95() -> float:
	return float(get_value("budget_default_p95", 16.6))


static func capture_shots() -> bool:
	return bool(get_value("capture_shots", false))


static func mcp_enabled() -> bool:
	return bool(get_value("mcp_enabled", false))


static func strip_paths() -> bool:
	return bool(get_value("strip_paths", true))


static func hash_project_name() -> bool:
	return bool(get_value("hash_project_name", false))


static func keep_captures() -> int:
	return maxi(1, int(get_value("keep_captures", 50)))


## 让这些键出现在「项目设置」里（由 EditorPlugin 调一次）
static func register_property_infos() -> void:
	var infos := [
		["enabled", TYPE_BOOL, "总开关：关掉后 BB 完全不做任何事"],
		["ring_capacity", TYPE_INT, "环形缓冲帧数（1800 ≈ 30 秒 @60fps）"],
		["probe_mode", TYPE_STRING, "探针模式：off / count / time"],
		["max_overhead_ms", TYPE_FLOAT, "采集自身上限（毫秒），超过自动降级"],
		["budget_default_p95", TYPE_FLOAT, "默认 p95 预算（毫秒，60fps 约 16.6）"],
		["capture_shots", TYPE_BOOL, "掉帧时截取画面（会额外花钱，默认关）"],
		["mcp_enabled", TYPE_BOOL, "开放 MCP 接口（默认关）"],
		["strip_paths", TYPE_BOOL, "导出时去掉本机绝对路径"],
		["hash_project_name", TYPE_BOOL, "导出时把项目名替换为哈希"],
		["keep_captures", TYPE_INT, "captures 目录最多保留多少个包（LRU）"],
	]
	for info in infos:
		var name := PREFIX + String(info[0])
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, DEFAULTS[info[0]])
		ProjectSettings.set_initial_value(name, DEFAULTS[info[0]])
		ProjectSettings.add_property_info({
			"name": name,
			"type": info[1],
			"hint": PROPERTY_HINT_NONE,
			"hint_string": String(info[2]),
		})


## 存储轮转：按修改时间从新到旧，保留前 keep 个 .bhx（以及同名的报告/提示词）
static func rotate_storage(dir: String, keep := -1) -> int:
	var limit := keep if keep > 0 else keep_captures()
	if not DirAccess.dir_exists_absolute(dir):
		return 0
	var entries := []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() != "bhx":
			continue
		var path := dir.path_join(f)
		entries.append({"path": path, "mtime": FileAccess.get_modified_time(path)})
	if entries.size() <= limit:
		return 0
	entries.sort_custom(func(a, b): return a["mtime"] > b["mtime"])
	var removed := 0
	for i in range(limit, entries.size()):
		var p := String(entries[i]["path"])
		var related := [p, p.get_basename() + ".report.md", p.get_basename() + ".prompt.md"]
		for rp in related:
			if FileAccess.file_exists(rp):
				if DirAccess.remove_absolute(rp) == OK:
					removed += 1
	return removed


## 路径脱敏（递归，返回新对象，不改原字典）
static func strip(value: Variant) -> Variant:
	if not strip_paths():
		return value
	if value is Dictionary:
		var out := {}
		for k in value:
			out[k] = strip(value[k])
		return out
	if value is Array:
		var arr := []
		for v in value:
			arr.append(strip(v))
		return arr
	if value is String:
		return strip_string(value)
	return value


static func strip_string(s: String) -> String:
	if s.is_empty():
		return s
	var out := s
	# 本机绝对路径（Windows / Unix）统一替换，避免泄露用户名与目录结构
	out = _strip_absolute(out)
	if out.begins_with("user://"):
		out = "<user>/" + out.substr("user://".length())
	if out.begins_with("res://"):
		out = "<project>/" + out.substr("res://".length())
	return out


static func _strip_absolute(s: String) -> String:
	var idx := -1
	for candidate in [":\\", ":/"]:
		var i := s.find(candidate)
		if i >= 0 and (idx < 0 or i < idx):
			idx = i
	var is_abs := idx >= 0 or s.begins_with("/") or s.begins_with("\\\\")
	if not is_abs:
		return s
	# 只保留最后两段：既保留可读性（game/scene.tscn），又不泄露用户名与目录结构
	var parts := s.replace("\\", "/").split("/", false)
	if parts.size() >= 2:
		return "<abs>/" + parts[parts.size() - 2] + "/" + parts[parts.size() - 1]
	if parts.size() == 1:
		return "<abs>/" + parts[0]
	return s


## 项目名脱敏：默认原样，开启后给哈希
static func project_name(project_name_in: String) -> String:
	if not hash_project_name():
		return project_name_in
	return "project_%08x" % hash(project_name_in)

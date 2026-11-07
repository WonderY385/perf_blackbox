@tool
class_name BBMcpServer
extends RefCounted
## F2 MCP server 的**逻辑层**（不含传输）。
##
## 只做一件设计文档强调的事：把已经落盘的 `.bhx` 当作证据，用瘦工具喂给 AI 客户端。
## 工具刻意保持少而小（每个返回都带「这是证据不是结论」的措辞），避免变成第二个 Render Lens。
##
## 传输层在 `tools/bb_mcp.gd`：stdio + 按行分隔的 JSON-RPC 2.0（MCP stdio 规范）。

const PROTOCOL_VERSION := "2024-11-05"
const SERVER_NAME := "perf_blackbox"
const SERVER_VERSION := "0.4.0"


## 返回 tools/list 需要的描述（inputSchema 手写，够用即可）。
static func tool_definitions() -> Array:
	return [
		{
			"name": "bb_list_packs",
			"description": "列出本机采集包（.bhx），含事件数与帧数。",
			"inputSchema": {"type": "object", "properties": {
				"dir": {"type": "string", "description": "可选：自定义目录"},
			}},
		},
		{
			"name": "bb_pack_events",
			"description": "读一个 .bhx 的事件表与每条的归因结论（root_cause / 置信度 / 证据 id）。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string", "description": ".bhx 文件路径"},
			}, "required": ["pack"]},
		},
		{
			"name": "bb_event_detail",
			"description": "读单个事件的完整证据：时间线抽稀、脚本/实体/计数三类增量、候选与已排除项。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
				"event_id": {"type": "string", "description": "如 evt_0001"},
			}, "required": ["pack", "event_id"]},
		},
		{
			"name": "bb_report",
			"description": "生成人读的 Markdown 报告（直接贴给人看）。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
			}, "required": ["pack"]},
		},
		{
			"name": "bb_prompt",
			"description": "生成给 AI 的提示词包（带硬约束与 evidence_id，≤max_tokens）。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
				"max_tokens": {"type": "number", "description": "默认 2000"},
			}, "required": ["pack"]},
		},
		{
			"name": "bb_timeline",
			"description": "生成自包含 HTML 时间线（max/median 双曲线 + 事件窗口）。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
				"save": {"type": "boolean", "description": "true 则落盘并返回路径"},
			}, "required": ["pack"]},
		},
		{
			"name": "bb_render_manifest",
			"description": "对场景跑静态渲染清单（网格/材质/阴影/灯/透明/粒子），输出 Markdown。",
			"inputSchema": {"type": "object", "properties": {
				"scene": {"type": "string", "description": "res:// 场景路径"},
			}, "required": ["scene"]},
		},
		{
			"name": "bb_regression",
			"description": "对比两份 .bhx：帧时间差 + 噪声底 + 事件增删 + 退出码（0 通过 / 2 退化）。",
			"inputSchema": {"type": "object", "properties": {
				"baseline": {"type": "string"},
				"current": {"type": "string"},
			}, "required": ["baseline", "current"]},
		},
		{
			"name": "bb_budget_gate",
			"description": "按预算/基线判定一份包是 pass/warn/fail/insufficient。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
			}, "required": ["pack"]},
		},
		{
			"name": "bb_correlate",
			"description": "把 .bhx 的事件证据与场景静态清单交叉，产出可验证假设（含实验步骤）。",
			"inputSchema": {"type": "object", "properties": {
				"pack": {"type": "string"},
				"scene": {"type": "string"},
			}, "required": ["pack", "scene"]},
		},
	]


## 处理一条 JSON-RPC 请求，返回响应字典；通知类返回空字典（不应该回复）。
static func handle(request: Dictionary) -> Dictionary:
	var id = request.get("id", null)
	var method := String(request.get("method", ""))
	var is_notification: bool = not request.has("id")
	if method == "initialize":
		return _ok(id, {
			"protocolVersion": PROTOCOL_VERSION,
			"capabilities": {"tools": {"listChanged": false}},
			"serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
		})
	if method in ["notifications/initialized", "initialized"] or is_notification:
		return {}
	if method == "ping":
		return _ok(id, {})
	if method == "tools/list":
		return _ok(id, {"tools": tool_definitions()})
	if method == "tools/call":
		var params: Dictionary = request.get("params", {})
		return _ok(id, _call_tool(String(params.get("name", "")), params.get("arguments", {})))
	if method == "resources/list":
		return _ok(id, {"resources": []})
	if method == "prompts/list":
		return _ok(id, {"prompts": []})
	return {
		"jsonrpc": "2.0",
		"id": _clean_id(id),
		"error": {"code": -32601, "message": "未知方法：%s" % method},
	}


static func _call_tool(name: String, args) -> Dictionary:
	var a: Dictionary = args if args is Dictionary else {}
	match name:
		"bb_list_packs":
			return _text(_tool_list_packs(String(a.get("dir", ""))))
		"bb_pack_events":
			return _text(_tool_events(String(a.get("pack", ""))))
		"bb_event_detail":
			return _text(_tool_event_detail(String(a.get("pack", "")), String(a.get("event_id", ""))))
		"bb_report":
			return _text(_with_pack(String(a.get("pack", "")),
				func(pack): return BBReport.build(pack, {"lang": "zh"})))
		"bb_prompt":
			return _text(_with_pack(String(a.get("pack", "")),
				func(pack): return BBPromptPack.build(pack, {"max_tokens": int(a.get("max_tokens", 2000))})))
		"bb_timeline":
			return _text(_tool_timeline(String(a.get("pack", "")), bool(a.get("save", false))))
		"bb_render_manifest":
			return _text(_tool_manifest(String(a.get("scene", ""))))
		"bb_regression":
			return _text(_tool_regression(String(a.get("baseline", "")), String(a.get("current", ""))))
		"bb_budget_gate":
			return _text(_tool_budget(String(a.get("pack", ""))))
		"bb_correlate":
			return _text(_tool_correlate(String(a.get("pack", "")), String(a.get("scene", ""))))
		_:
			return {"content": [{"type": "text", "text": "未知工具：%s" % name}], "isError": true}


static func _tool_list_packs(dir: String) -> String:
	var packs := BBPackReader.list_captures(dir)
	if packs.is_empty():
		return "没有采集包。先运行游戏并调用 BB.start_capture() / BB.capture_next_hitch()。"
	var lines: PackedStringArray = []
	for p in packs:
		var info := BBPackReader.read_manifest(p)
		lines.append("- `%s`（事件 %d，帧 %d）" % [
			p, int(info.get("event_count", 0)),
			int((info.get("capture", {}) as Dictionary).get("frames", 0))])
	return "\n".join(lines)


static func _tool_events(path: String) -> String:
	var pack := _read(path)
	if pack.has("error"):
		return String(pack["error"])
	var deltas: Dictionary = pack.get("deltas", {})
	var lines: PackedStringArray = ["# 事件表", ""]
	for ev in pack.get("events", []):
		var e: Dictionary = ev
		var d: Dictionary = deltas.get(e.get("id", ""), {})
		lines.append("- `%s` 峰值帧 %d：%.1fms（基线 %.1fms，%.2f×，%s）→ 归因 `%s`（置信 %.2f）" % [
			String(e.get("id", "")), int(e.get("peak_frame", -1)),
			float(e.get("peak_ms", 0.0)), float(e.get("baseline_ms", 0.0)),
			float(e.get("ratio", 0.0)), String(e.get("severity", "")),
			String(d.get("root_cause", "inconclusive")), float(d.get("confidence", 0.0))])
	if (pack.get("events", []) as Array).is_empty():
		lines.append("这次采集没有掉帧事件（基线包）。")
	return "\n".join(lines)


static func _tool_event_detail(path: String, event_id: String) -> String:
	var pack := _read(path)
	if pack.has("error"):
		return String(pack["error"])
	var ev := {}
	for e in pack.get("events", []):
		if String((e as Dictionary).get("id", "")) == event_id:
			ev = e
			break
	if ev.is_empty():
		return "找不到事件 `%s`" % event_id
	var d: Dictionary = (pack.get("deltas", {}) as Dictionary).get(event_id, {})
	return BBReport.build_event_digest(pack, ev, d)


static func _tool_timeline(path: String, save: bool) -> String:
	var pack := _read(path)
	if pack.has("error"):
		return String(pack["error"])
	var html := BBTimeline.build_html(pack)
	if not save:
		return "已生成 HTML（%d 字节）。传 `save: true` 可落盘拿到路径。\n\n" % html.length()
	var out := BBPackReader.capture_dir().path_join(path.get_file().get_basename() + ".timeline.html")
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f == null:
		return "生成成功但无法写盘：%s" % out
	f.store_string(html)
	f.close()
	return "已写：%s（%d 字节）" % [out, html.length()]


static func _tool_manifest(scene: String) -> String:
	var manifest := BBRenderManifest.build_from_scene_path(scene)
	if manifest.has("error"):
		return String(manifest["error"])
	return String(manifest.get("markdown", ""))


static func _tool_regression(a_path: String, b_path: String) -> String:
	var a := _read(a_path)
	var b := _read(b_path)
	if a.has("error"):
		return String(a["error"])
	if b.has("error"):
		return String(b["error"])
	var res := BBRegression.compare(a, b, {})
	return BBRegression.build_md(res, {"baseline_label": a_path.get_file(), "current_label": b_path.get_file()})


static func _tool_budget(path: String) -> String:
	var pack := _read(path)
	if pack.has("error"):
		return String(pack["error"])
	var summary := BBBudget.summarize(pack)
	var scene := String(summary.get("scene", ""))
	var res := BBBudget.evaluate(summary, BBBudget.load_budget(scene), BBBudget.load_baseline(scene))
	return "state=%s p50=%.2fms p95=%.2fms max=%.2fms drift=%.1f%%\nnotes=%s" % [
		String(res.get("state", "")), float(res.get("p50", -1.0)), float(res.get("p95", -1.0)),
		float(res.get("max", -1.0)), float(res.get("drift", 0.0)) * 100.0,
		"; ".join(PackedStringArray(res.get("notes", [])))]


static func _tool_correlate(pack_path: String, scene: String) -> String:
	var pack := _read(pack_path)
	if pack.has("error"):
		return String(pack["error"])
	var manifest := BBRenderManifest.build_from_scene_path(scene)
	if manifest.has("error"):
		return String(manifest["error"])
	return String(BBCorrelate.correlate(pack, manifest).get("markdown", ""))


static func _with_pack(path: String, fn: Callable) -> String:
	var pack := _read(path)
	if pack.has("error"):
		return String(pack["error"])
	return String(fn.call(pack))


static func _read(path: String) -> Dictionary:
	if path == "":
		return {"error": "缺少 .bhx 路径"}
	if not FileAccess.file_exists(path):
		return {"error": "文件不存在：%s" % path}
	var pack := BBPackReader.read(path)
	if pack.is_empty():
		return {"error": "无法读取：%s" % path}
	return pack


static func _text(text: String) -> Dictionary:
	return {"content": [{"type": "text", "text": text}]}


static func _ok(id, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _clean_id(id), "result": result}


## JSON 没有整数类型：`JSON.parse_string("{\"id\":1}")` 拿到的是 1.0（float）。
## MCP 要求响应里的 id 与请求**完全一致**，所以把「整数值的 float」还原成 int。
static func _clean_id(id):
	if id is float:
		var f: float = id
		if is_finite(f) and f == floorf(f) and absf(f) < 9007199254740992.0:
			return int(f)
	return id

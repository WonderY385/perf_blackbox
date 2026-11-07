@tool
extends Control
## F1 编辑器面板：只读 `.bhx` 文件 + BB 公开字典，不做任何测量或业务逻辑。
## 采集发生在运行中的游戏里（BB autoload）；编辑器侧只负责「看」与「导出」。

const PANEL_MIN_HEIGHT := 260
const CONTENT_MARGIN := 8
const SCAN_INTERVAL_S := 1.0

var content: VBoxContainer

var _dir_label: Label
var _status_label: Label
var _list: ItemList
var _tree: Tree
var _tabs: TabContainer
var _causes_view: RichTextLabel
var _report_view: RichTextLabel
var _prompt_view: RichTextLabel
var _diag_view: RichTextLabel
var _timeline: BBTimelineView
var _auto_refresh: CheckBox
var _export_md: Button
var _export_prompt: Button
var _export_html: Button

var _paths: PackedStringArray = PackedStringArray()
var _pack: Dictionary = {}
var _loaded_path := ""
var _scan_accum := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(0, PANEL_MIN_HEIGHT)
	size_flags_vertical = SIZE_EXPAND_FILL
	_build_shell()
	refresh_list()


func _build_shell() -> void:
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", CONTENT_MARGIN)
	add_child(margin)

	content = VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = SIZE_EXPAND_FILL
	content.size_flags_vertical = SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	content.add_child(_build_toolbar())

	var split := HSplitContainer.new()
	split.name = "Split"
	split.size_flags_horizontal = SIZE_EXPAND_FILL
	split.size_flags_vertical = SIZE_EXPAND_FILL
	split.split_offset = 260
	content.add_child(split)

	_list = ItemList.new()
	_list.name = "Captures"
	_list.custom_minimum_size = Vector2(220, 0)
	_list.size_flags_vertical = SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	split.add_child(_list)

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_horizontal = SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = SIZE_EXPAND_FILL
	split.add_child(_tabs)

	_tree = Tree.new()
	_tree.name = "Events"
	_tree.columns = 7
	_tree.set_column_title(0, "id")
	_tree.set_column_title(1, "峰值帧")
	_tree.set_column_title(2, "峰值 ms")
	_tree.set_column_title(3, "基线 ms")
	_tree.set_column_title(4, "倍数")
	_tree.set_column_title(5, "分级")
	_tree.set_column_title(6, "归因")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.item_selected.connect(_on_event_selected)
	_tabs.add_child(_tree)
	_tabs.set_tab_title(0, "事件")

	_causes_view = _make_text_tab("原因")
	_report_view = _make_text_tab("报告")
	_prompt_view = _make_text_tab("提示词")
	_diag_view = _make_text_tab("诊断")

	# C3 时间线：紧跟在「事件」后面（看事件 → 看它长什么样是自然顺序）
	_timeline = BBTimelineView.new()
	_timeline.name = "Timeline"
	_tabs.add_child(_timeline)
	_tabs.move_child(_timeline, 1)
	_tabs.set_tab_title(1, "时间线")


func _build_toolbar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.name = "Toolbar"
	bar.add_theme_constant_override("separation", 6)

	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.tooltip_text = "重新扫描采集目录"
	refresh.pressed.connect(refresh_list)
	bar.add_child(refresh)

	_auto_refresh = CheckBox.new()
	_auto_refresh.text = "自动"
	_auto_refresh.button_pressed = true
	_auto_refresh.tooltip_text = "每秒扫描一次（新包出现时自动列表）"
	bar.add_child(_auto_refresh)

	_dir_label = Label.new()
	_dir_label.text = BBPackReader.capture_dir()
	_dir_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_dir_label.clip_text = true
	_dir_label.modulate = Color(1, 1, 1, 0.55)
	bar.add_child(_dir_label)

	_export_md = Button.new()
	_export_md.text = "导出报告"
	_export_md.disabled = true
	_export_md.pressed.connect(_export_selected.bind("md"))
	bar.add_child(_export_md)

	_export_prompt = Button.new()
	_export_prompt.text = "导出提示词"
	_export_prompt.disabled = true
	_export_prompt.pressed.connect(_export_selected.bind("prompt"))
	bar.add_child(_export_prompt)

	_export_html = Button.new()
	_export_html.text = "导出 HTML 时间线"
	_export_html.disabled = true
	_export_html.tooltip_text = "生成自包含 HTML：双击即开，可发给别人看，不需要编辑器"
	_export_html.pressed.connect(_export_selected.bind("html"))
	bar.add_child(_export_html)

	var wizard := Button.new()
	wizard.text = "接入向导"
	wizard.tooltip_text = "扫项目/当前场景，给出「先测什么、给哪些函数装探针」的清单"
	wizard.pressed.connect(_run_wizard)
	bar.add_child(wizard)

	var manifest_btn := Button.new()
	manifest_btn.text = "渲染清单"
	manifest_btn.tooltip_text = "导出当前场景的静态渲染清单（网格/材质/阴影/灯/透明）"
	manifest_btn.pressed.connect(_run_render_manifest)
	bar.add_child(manifest_btn)

	_status_label = Label.new()
	_status_label.text = "等待采集…"
	bar.add_child(_status_label)
	return bar


## D4：对当前场景跑接入向导，结果直接进「诊断」页。
func _run_wizard() -> void:
	var bb = get_node_or_null("/root/BB")
	if bb == null:
		_set_tab_texts("运行时才有 BB 单例；编辑器里也可用 bb_cli --manifest= 走无头路径。")
		return
	var res: Dictionary = bb.wizard_for_scene()
	var text := String(res.get("markdown", ""))
	if text == "":
		text = JSON.stringify(res, "  ")
	_diag_view.text = text
	var idx := _tab_index("诊断")
	if idx >= 0:
		_tabs.current_tab = idx
	_status_label.text = "向导已生成"


## E1：导出当前场景的静态清单，写文件并展示。
func _run_render_manifest() -> void:
	var bb = get_node_or_null("/root/BB")
	if bb == null:
		_set_tab_texts("运行时才有 BB 单例；编辑器里可用 bb_cli --manifest=res://你的场景.tscn")
		return
	var res: Dictionary = bb.render_manifest()
	if res.has("error"):
		_diag_view.text = "渲染清单失败：%s" % String(res.get("error", ""))
		return
	var written: Dictionary = bb.export_render_manifest()
	var text := String(res.get("markdown", ""))
	if not written.has("error"):
		text += "\n\n已写：`%s`\n" % String(written.get("path", ""))
	_diag_view.text = text
	var idx := _tab_index("诊断")
	if idx >= 0:
		_tabs.current_tab = idx
	_status_label.text = "渲染清单已生成"


func _tab_index(title: String) -> int:
	for i in _tabs.get_tab_count():
		if _tabs.get_tab_title(i) == title:
			return i
	return -1


func _make_text_tab(title: String) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.name = title
	rt.bbcode_enabled = false
	rt.fit_content = false
	rt.scroll_active = true
	rt.selection_enabled = true
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.size_flags_horizontal = SIZE_EXPAND_FILL
	rt.size_flags_vertical = SIZE_EXPAND_FILL
	_tabs.add_child(rt)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, title)
	return rt


# --- 列表与加载 -------------------------------------------------------------

func refresh_list() -> void:
	var dir_path := BBPackReader.capture_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		_paths = PackedStringArray()
		_list.clear()
		_status_label.text = "还没有采集文件"
		_dir_label.text = dir_path
		return

	_paths = PackedStringArray()
	var names := DirAccess.get_files_at(dir_path)
	for n in names:
		if n.get_extension().to_lower() == "bhx":
			_paths.append(dir_path.path_join(n))
	_paths.sort()

	var selected := _list.get_selected_items()
	var selected_path := ""
	if selected.size() > 0 and selected[0] < _paths.size() and selected[0] < _list.item_count:
		selected_path = String(_list.get_item_metadata(selected[0]))

	_list.clear()
	for p in _paths:
		var idx := _list.add_item(p.get_file())
		_list.set_item_metadata(idx, p)
	if selected_path != "":
		for i in _list.item_count:
			if String(_list.get_item_metadata(i)) == selected_path:
				_list.select(i)
				break
	elif _list.item_count > 0:
		# 首次打开/包列表变化：自动选中最新一个，省得用户还要点一下
		var pick := _list.item_count - 1
		_list.select(pick)
		load_pack(String(_list.get_item_metadata(pick)))
	_dir_label.text = dir_path
	_status_label.text = "%d 个包" % _paths.size()
	if _paths.is_empty():
		_set_tab_texts("采集目录是空的。运行游戏后调用 `BB.capture_next_hitch()`，或用面板上方的导出按钮从已有包生成报告。")
	else:
		_export_md.disabled = _loaded_path == ""
		_export_prompt.disabled = _loaded_path == ""


func _on_item_selected(index: int) -> void:
	if index < 0 or index >= _list.item_count:
		return
	var path := String(_list.get_item_metadata(index))
	load_pack(path)


func load_pack(path: String) -> void:
	var result := BBPackReader.read(path)
	if result.has("error"):
		_status_label.text = "读取失败：%s" % String(result.get("error", "unknown"))
		return
	_pack = result
	_loaded_path = path
	_export_md.disabled = false
	_export_prompt.disabled = false
	_export_html.disabled = false
	_status_label.text = "%s · %d 帧 · %d 事件" % [
		path.get_file(), int(_pack.get("frames", 0)), _pack.get("events", []).size()]
	_fill_events()
	_timeline.set_pack(_pack)
	_fill_report()
	_fill_prompt()
	_fill_diag()


func _fill_events() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var events: Array = _pack.get("events", [])
	var deltas: Dictionary = _pack.get("deltas", {})
	for ev in events:
		var item := _tree.create_item(root)
		var d: Dictionary = deltas.get(ev.get("id", ""), {})
		item.set_text(0, String(ev.get("id", "")))
		item.set_text(1, str(int(ev.get("peak_frame", -1))))
		item.set_text(2, "%.1f" % float(ev.get("peak_ms", 0.0)))
		item.set_text(3, "%.1f" % float(ev.get("baseline_ms", 0.0)))
		item.set_text(4, "%.1f×" % float(ev.get("ratio", 0.0)))
		item.set_text(5, String(ev.get("severity", "")))
		item.set_text(6, String(d.get("root_cause", "inconclusive")))
		item.set_metadata(0, ev.get("id", ""))
	if events.is_empty():
		_causes_view.text = "这个包里没有掉帧事件（它是一份基线包）。\n\n帧数：%d" % int(_pack.get("frames", 0))
	else:
		_tree.get_root().get_first_child().select(0)
		_on_event_selected()


func _on_event_selected() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var id := String(item.get_metadata(0))
	var ev: Dictionary = {}
	var deltas: Dictionary = _pack.get("deltas", {})
	for e in _pack.get("events", []):
		if String(e.get("id", "")) == id:
			ev = e
			break
	var d: Dictionary = deltas.get(id, {})
	_causes_view.text = BBReport.build_event_digest(_pack, ev, d)


func _fill_report() -> void:
	_report_view.text = BBReport.build(_pack, {"lang": "zh"})


func _fill_prompt() -> void:
	_prompt_view.text = BBPromptPack.build(_pack, {"max_tokens": 2000})


func _fill_diag() -> void:
	var m: Dictionary = _pack.get("manifest", {})
	var diag: Dictionary = m.get("diagnostics", {})
	var capture: Dictionary = m.get("capture", {})
	var lines := PackedStringArray()
	lines.append("文件：%s" % _loaded_path)
	lines.append("schema：v%d · 工具 %s" % [int(_pack.get("schema_version", 1)), String(m.get("tool", {}).get("version", "?"))])
	lines.append("帧数：%d（起始帧 %d，容量 %d）" % [
		int(_pack.get("frames", 0)), int(_pack.get("start_frame", 0)), int(capture.get("capacity", 0))])
	lines.append("采样列：%d" % (capture.get("columns", []) as Array).size())
	lines.append("探针 id 数：%d · 探针帧数：%d" % [
		int(diag.get("probe_ids", 0)), int(diag.get("probe_frames", 0))])
	lines.append("")
	lines.append("## 不可用的列")
	var unavailable: Dictionary = diag.get("unavailable_columns", {})
	if unavailable.is_empty():
		lines.append("（无，全部数据源可用）")
	for col_name in unavailable:
		lines.append("- %s：%s" % [col_name, unavailable[col_name]])
	lines.append("")
	lines.append("## 本版本结构性缺口")
	var sources: Dictionary = diag.get("unavailable_sources", {})
	for k in sources:
		lines.append("- %s：%s" % [k, sources[k]])
	lines.append("")
	lines.append("## 采集期降级")
	var degradations: Array = capture.get("degradations", [])
	if degradations.is_empty():
		lines.append("（无降级）")
	for d in degradations:
		lines.append("- %s" % String(d))
	lines.append("")
	lines.append("## 自身开销")
	var overhead: Dictionary = diag.get("overhead", {})
	lines.append("档位 L%d · 平均 %.3f ms/帧 · 预算 %.3f ms/帧" % [
		int(overhead.get("level", 0)), float(overhead.get("mean_ms", 0.0)), float(overhead.get("budget_ms", 0.0))])
	lines.append("")
	lines.append("## 预算与基线（D1）")
	var summary := BBBudget.summarize(_pack)
	var scene_name := String(summary.get("scene", ""))
	var budget := BBBudget.load_baseline(scene_name)
	var evaluated := BBBudget.evaluate(summary, {"p95": BBSettings.budget_default_p95(), "max": 0.0}, budget)
	lines.append("状态：%s · p50 %.2f ms · p95 %.2f ms · p99 %.2f ms · max(p99.9) %.2f ms" % [
		String(evaluated.get("state", "?")).to_upper(), float(evaluated.get("p50", 0.0)),
		float(evaluated.get("p95", 0.0)), float(evaluated.get("p99", 0.0)), float(evaluated.get("max", 0.0))])
	lines.append("有效帧：%d / %d（已剔除前 %.0f ms 预热）" % [
		int(summary.get("frames_used", 0)), int(summary.get("frames_total", 0)), float(summary.get("warmup_ms", 0.0))])
	lines.append("基线：%s" % BBBudget.baseline_path(scene_name))
	for n in evaluated.get("notes", []):
		lines.append("- %s" % String(n))
	lines.append("")
	lines.append("## 引擎")
	var engine: Dictionary = m.get("engine", {})
	lines.append("%s · %s / %s · %s" % [
		String(engine.get("version", "?")), String(engine.get("renderer", "?")),
		String(engine.get("driver", "?")), String(engine.get("physics", "?"))])
	lines.append("settings_hash：%s" % String(m.get("settings_hash", "?")))
	var pre: Dictionary = m.get("measure_preconditions", {})
	lines.append("v-sync=%s · max_fps=%s · headless=%s" % [
		pre.get("vsync", "?"), pre.get("max_fps", "?"), pre.get("headless", "?")])
	_diag_view.text = "\n".join(lines)


func _set_tab_texts(msg: String) -> void:
	_tree.clear()
	_causes_view.text = msg
	_report_view.text = msg
	_prompt_view.text = msg
	_diag_view.text = msg
	if _timeline != null:
		_timeline.set_data({})


# --- 导出 -------------------------------------------------------------------

func _export_selected(format: String) -> void:
	if _pack.is_empty() or _loaded_path == "":
		return
	var base := _loaded_path.get_basename()
	var target := base
	match format:
		"md":
			target = base + ".report.md"
		"prompt":
			target = base + ".prompt.md"
		"html":
			target = base + ".timeline.html"
		_:
			pass
	var result := {}
	if format == "md":
		result = _write_text(target, BBReport.build(_pack, {"lang": "zh"}))
	elif format == "prompt":
		result = _write_text(target, BBPromptPack.build(_pack, {"max_tokens": 2000}))
	elif format == "html":
		result = _write_text(target, BBTimeline.build_html(_pack))
	else:
		result = {"ok": false, "error": "unsupported"}
	if bool(result.get("ok", false)):
		_status_label.text = "已导出 %s" % target.get_file()
	else:
		_status_label.text = "导出失败：%s" % String(result.get("error", ""))
	refresh_list()


func _write_text(path: String, text: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": path}
	f.store_string(text)
	f.close()
	return {"ok": true, "path": path}


# --- 自动刷新 ---------------------------------------------------------------

func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if _auto_refresh == null or not _auto_refresh.button_pressed:
		return
	_scan_accum += delta
	if _scan_accum < SCAN_INTERVAL_S:
		return
	_scan_accum = 0.0
	var before := _paths.size()
	if DirAccess.dir_exists_absolute(BBPackReader.capture_dir()):
		var found := 0
		for n in DirAccess.get_files_at(BBPackReader.capture_dir()):
			if n.get_extension().to_lower() == "bhx":
				found += 1
		if found != before:
			refresh_list()

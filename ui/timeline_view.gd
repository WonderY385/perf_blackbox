@tool
class_name BBTimelineView
extends Control
## C3 面板内的时间线视图：纯绘制，不含业务逻辑。
## 数据来自 `BBTimeline.build_data()`；悬停显示数值，点击发出 frame_selected。
##
## 画两条线而不是一条：红线是每桶最大值（掉帧尖峰），蓝线是每桶中位数（常态）。
## 只有一条线时会误判——只看中位数会漏掉尖刺，只看最大值则看不出稳态抖动。

signal frame_selected(abs_frame: int)

const PAD_LEFT := 46.0
const PAD_RIGHT := 10.0
const PAD_TOP := 12.0
const PAD_BOTTOM := 22.0
const COLOR_MAX := Color("#e0575b")
const COLOR_MEDIAN := Color("#4aa8ff")
const COLOR_GRID := Color("#2a3038")
const COLOR_TEXT := Color("#8b95a3")
const COLOR_EVENT := Color(1.0, 0.82, 0.4, 0.12)
const COLOR_HOVER := Color("#5b6673")

var _data: Dictionary = {}
var _hover := -1


func _ready() -> void:
	custom_minimum_size = Vector2(0, 240)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_pack(pack: Dictionary) -> void:
	set_data(BBTimeline.build_data(pack))


func set_data(data: Dictionary) -> void:
	_data = data
	_hover = -1
	queue_redraw()


func get_data() -> Dictionary:
	return _data


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color("#191c21"))
	var region := Rect2(PAD_LEFT, PAD_TOP, maxf(1.0, size.x - PAD_LEFT - PAD_RIGHT), maxf(1.0, size.y - PAD_TOP - PAD_BOTTOM))
	var maxs: Array = _data.get("max", [])
	if maxs.is_empty():
		var f := ThemeDB.fallback_font
		draw_string(f, Vector2(PAD_LEFT, PAD_TOP + 20), "无数据：先用 BB.stop_capture() 采集一次，或在上方列表里选一个 .bhx", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, COLOR_TEXT)
		return

	var ymax := 16.7
	for v in maxs:
		if float(v) > ymax:
			ymax = float(v)
	ymax *= 1.1
	var font := ThemeDB.fallback_font

	# 网格 + y 轴刻度
	for i in 5:
		var v := ymax * float(i) / 4.0
		var y := region.position.y + region.size.y - (v / ymax) * region.size.y
		draw_line(Vector2(region.position.x, y), Vector2(region.position.x + region.size.x, y), COLOR_GRID, 1.0)
		draw_string(font, Vector2(4, y + 4), "%.1fms" % v, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, COLOR_TEXT)

	# 事件窗口
	for ev in _data.get("events", []):
		var a := int(ev.get("from_bucket", -1))
		var b := int(ev.get("to_bucket", -1))
		if a < 0 or b < a:
			continue
		var x0 := _x_at(a, region)
		var x1 := _x_at(b + 1, region)
		draw_rect(Rect2(x0, region.position.y, maxf(2.0, x1 - x0), region.size.y), COLOR_EVENT)
		draw_string(font, Vector2(x0 + 3, region.position.y + 11), String(ev.get("id", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 0.82, 0.4, 0.8))

	_draw_series(_data.get("median", []), region, ymax, COLOR_MEDIAN, 1.0)
	_draw_series(maxs, region, ymax, COLOR_MAX, 2.0)

	# 抽样提示
	if int(_data.get("bucket_width", 1)) > 1:
		draw_string(font, Vector2(region.position.x + region.size.x - 160, region.position.y + 12),
			"每桶 %d 帧" % int(_data["bucket_width"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, COLOR_TEXT)

	if _hover >= 0 and _hover < maxs.size():
		var hx := _x_at(_hover, region)
		draw_line(Vector2(hx, region.position.y), Vector2(hx, region.position.y + region.size.y), COLOR_HOVER, 1.0)
		var from_arr: Array = _data.get("from", [])
		var to_arr: Array = _data.get("to", [])
		var med_arr: Array = _data.get("median", [])
		var from_f := int(_data.get("start_frame", 0)) + (int(from_arr[_hover]) if _hover < from_arr.size() else 0)
		var to_f := int(_data.get("start_frame", 0)) + (int(to_arr[_hover]) if _hover < to_arr.size() else 0)
		var med_v := float(med_arr[_hover]) if _hover < med_arr.size() else float(maxs[_hover])
		var label := "帧 %d~%d · max %.2f ms · p50 %.2f ms" % [from_f, to_f, float(maxs[_hover]), med_v]
		draw_string(font, Vector2(region.position.x + 8, region.position.y + 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#d7dce2"))


func _draw_series(series: Array, region: Rect2, ymax: float, color: Color, width: float) -> void:
	var n := series.size()
	if n == 0:
		return
	if n == 1:
		var only := float(series[0])
		draw_circle(Vector2(region.position.x, region.position.y + region.size.y - clampf(only / ymax, 0.0, 1.0) * region.size.y), width + 1.0, color)
		return
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var v := float(series[i])
		if v < 0.0:
			v = 0.0
		pts[i] = Vector2(_x_at(i, region), region.position.y + region.size.y - clampf(v / ymax, 0.0, 1.0) * region.size.y)
	draw_polyline(pts, color, width, true)


func _x_at(idx: int, region: Rect2) -> float:
	var n := int(_data.get("max", []).size())
	if n <= 1:
		return region.position.x
	return region.position.x + (float(idx) / float(n - 1)) * region.size.x


func _gui_input(event: InputEvent) -> void:
	var maxs: Array = _data.get("max", [])
	if maxs.is_empty():
		return
	if event is InputEventMouseMotion:
		var region := Rect2(PAD_LEFT, PAD_TOP, maxf(1.0, size.x - PAD_LEFT - PAD_RIGHT), maxf(1.0, size.y - PAD_TOP - PAD_BOTTOM))
		var t := clampf(((event as InputEventMouseMotion).position.x - region.position.x) / region.size.x, 0.0, 1.0)
		_hover = clampi(int(round(t * float(maxs.size() - 1))), 0, maxs.size() - 1)
		queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var from_arr: Array = _data.get("from", [])
			if _hover >= 0 and _hover < from_arr.size():
				frame_selected.emit(int(_data.get("start_frame", 0)) + int(from_arr[_hover]))


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			_hover = -1
			queue_redraw()
		NOTIFICATION_RESIZED:
			queue_redraw()

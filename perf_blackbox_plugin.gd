@tool
extends EditorPlugin

## Perf Blackbox —— 插件入口。
##
## 当前能力：底部「PBb」面板（时间线/事件/原因/报告/提示词/诊断）+ 运行时单例 BB
## （采集、掉帧归因、.bhx 打包、预算判定、系统成本账本）。
## 采集本身发生在运行中的游戏里；编辑器侧只负责「看」与「导出」。

const PANEL_TITLE := "PBb"
const PANEL_SCRIPT := preload("ui/blackbox_panel.gd")

var _panel: Control = null


func _enter_tree() -> void:
	# F4：把 perf_blackbox/* 的设置项注册到「项目设置」，让用户能在编辑器里改
	BBSettings.register_property_infos()
	_panel = PANEL_SCRIPT.new()
	_panel.name = "BlackboxPanel"
	# 返回的 Button 不在场景树里，这里不保留引用；需要改标签文字时用 _get_panel_button()。
	add_control_to_bottom_panel(_panel, PANEL_TITLE)
	print("[Perf Blackbox] 底部面板已注册，标签: %s" % PANEL_TITLE)


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
	_panel = null


## 底部面板上那个标签按钮（由 add_control_to_bottom_panel 创建，宿主是底部面板容器）。
## 留给后续阶段改角标/颜色用，现在只做说明，不参与逻辑。
func _get_panel_button() -> Button:
	if not is_instance_valid(_panel) or _panel.get_parent() == null:
		return null
	var host := _panel.get_parent().get_parent()
	if host == null:
		return null
	for child in host.get_children():
		if child is Button and String(child.text) == PANEL_TITLE:
			return child
	return null

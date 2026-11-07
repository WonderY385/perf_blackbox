@tool
class_name BBEntityDelta
extends RefCounted
## B2 实体/场景激活增量：监听 SceneTree.node_added / node_removed，按帧记稀疏计数。
## 成本纪律：回调里只做 get_class() 与 scene_file_path 的比较 + int 自增，
## 绝不调用 get_path()（加载大场景时每节点都回调，get_path 会把帧拖穿）。

var _tree: SceneTree
var _cap := 2048

## abs_frame -> {"a": {key: count}, "r": {key: count}}
var _frames: Dictionary = {}
## key -> 首次出现的 abs_frame（整段录制内）
var _first_seen: Dictionary = {}
var _totals: Dictionary = {}

var _cur := 0
var _adds: Dictionary = {}
var _removed: Dictionary = {}

var _attached := false


func attach(tree: SceneTree) -> void:
	if tree == null or _attached:
		return
	_tree = tree
	tree.node_added.connect(_on_node_added)
	tree.node_removed.connect(_on_node_removed)
	_attached = true


func detach() -> void:
	if _tree != null and _attached:
		if _tree.node_added.is_connected(_on_node_added):
			_tree.node_added.disconnect(_on_node_added)
		if _tree.node_removed.is_connected(_on_node_removed):
			_tree.node_removed.disconnect(_on_node_removed)
	_attached = false


func begin_frame(abs_frame: int) -> void:
	_cur = abs_frame
	_adds = {}
	_removed = {}


func end_frame(abs_frame: int) -> void:
	if _adds.is_empty() and _removed.is_empty():
		return
	_frames[abs_frame] = {"a": _adds, "r": _removed}
	# 只保留最近 cap 帧
	if _frames.size() > _cap:
		var oldest := abs_frame - _cap
		if _frames.has(oldest):
			_frames.erase(oldest)


func _on_node_added(node: Node) -> void:
	var cls := node.get_class()
	_bump("class:" + cls, _adds)
	var scene := node.scene_file_path
	if scene != "":
		_bump("scene:" + scene, _adds)


func _on_node_removed(node: Node) -> void:
	var cls := node.get_class()
	_bump("class:" + cls, _removed)


func _bump(key: String, target: Dictionary) -> void:
	target[key] = int(target.get(key, 0)) + 1
	_totals[key] = int(_totals.get(key, 0)) + 1
	if not _first_seen.has(key):
		_first_seen[key] = _cur


## 事件窗口相对基线窗口的实体增量
func delta_for(base_from: int, base_to: int, win_from: int, win_to: int) -> Array[Dictionary]:
	var base_count := {}
	for f in range(maxi(base_from, base_to - 4096), base_to):
		var e = _frames.get(f)
		if e == null:
			continue
		for k in e["a"]:
			base_count[k] = int(base_count.get(k, 0)) + int(e["a"][k])

	var win_count := {}
	for f in range(win_from, win_to + 1):
		var e = _frames.get(f)
		if e == null:
			continue
		for k in e["a"]:
			win_count[k] = int(win_count.get(k, 0)) + int(e["a"][k])

	var out: Array[Dictionary] = []
	for k in win_count:
		var added := int(win_count[k]) - int(base_count.get(k, 0))
		if added <= 0:
			continue
		var key: String = k
		var kind := "node_class"
		var name := key
		if key.begins_with("scene:"):
			kind = "scene"
			name = key.substr(6)
		elif key.begins_with("class:"):
			name = key.substr(6)
		var entry := {
			"kind": kind,
			"key": name,
			"added": added,
			"baseline_count": int(base_count.get(k, 0)),
			"first_seen_frame": int(_first_seen.get(k, -1)),
			"in_baseline": base_count.has(k),
		}
		out.append(entry)

	# scene 条目补上它对应的节点类（从同一窗口的 class 计数里挑最大者）
	out.sort_custom(func(a, b): return int(a["added"]) > int(b["added"]))
	return out


## 窗口内的场景指纹（写 scene_snapshot.json 用）
func scene_fingerprint(win_from: int, win_to: int) -> Dictionary:
	var by_scene := {}
	for f in range(win_from, win_to + 1):
		var e = _frames.get(f)
		if e == null:
			continue
		for k in e["a"]:
			var key: String = k
			if key.begins_with("scene:"):
				var p := key.substr(6)
				by_scene[p] = int(by_scene.get(p, 0)) + int(e["a"][k])
	return {"new_scenes": by_scene}


func first_seen_frame(key: String) -> int:
	return int(_first_seen.get(key, -1))


func known_keys() -> int:
	return _totals.size()

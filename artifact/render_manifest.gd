@tool
class_name BBRenderManifest
extends RefCounted
## E1 渲染清单导出：把「当前场景里到底有什么」压成一份 token 友好的清单。
##
## 它不猜性能结论（那是 E2 和外部 AI 的事），只负责把**事实**摆成可计算的形式：
## 多少网格实例、多少个重复网格（MultiMesh 候选）、多少投射阴影的物体、
## 多少透明材质（overdraw 候选）、多少带阴影的灯、多少粒子。
##
## 设计约束：不遍历材质内部 shader 代码、不解析 .blend；只读节点属性与资源路径，
## 所以能在编辑器里对**编辑中的场景**直接跑，也能 headless 对 .tscn 跑。

const MAX_INDIVIDUAL_ENTRIES := 40   ## 明细最多列这么多条，其余折成「同类 ×N」
const DEFAULT_TOKEN_BUDGET := 1200


## 从编辑中的场景根节点构建。
static func build(root: Node, opts := {}) -> Dictionary:
	if root == null:
		return _empty("根节点为空")
	var mesh_sig := {}       ## 网格签名 -> 计数
	var material_sig := {}   ## 材质签名 -> 计数
	var classes := {}
	var totals := {
		"nodes": 0,
		"node3d": 0,
		"mesh_instances": 0,
		"multimesh_instances": 0,
		"csg": 0,
		"lights": 0,
		"light_shadows": 0,
		"particles": 0,
		"transparent_materials": 0,
		"shadow_casters": 0,
		"no_visibility_range": 0,
	}
	var _stack: Array[Node] = [root]
	while not _stack.is_empty():
		var n: Node = _stack.pop_back()
		totals["nodes"] += 1
		classes[n.get_class()] = int(classes.get(n.get_class(), 0)) + 1
		if n is Node3D:
			totals["node3d"] += 1
		if n is MeshInstance3D:
			totals["mesh_instances"] += 1
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				var sig := _mesh_signature(mi)
				mesh_sig[sig] = int(mesh_sig.get(sig, 0)) + 1
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				totals["shadow_casters"] += 1
			if mi.visibility_range_end <= 0.0 and mi.visibility_range_begin <= 0.0:
				totals["no_visibility_range"] += 1
			var mat_sig := _material_signature(mi)
			if mat_sig != "":
				material_sig[mat_sig] = int(material_sig.get(mat_sig, 0)) + 1
				if mat_sig.begins_with("transparent:"):
					totals["transparent_materials"] += 1
		elif n is MultiMeshInstance3D:
			totals["multimesh_instances"] += 1
			var mmi := n as MultiMeshInstance3D
			if mmi.multimesh != null:
				var msig := "multimesh:%d" % mmi.multimesh.instance_count
				mesh_sig[msig] = int(mesh_sig.get(msig, 0)) + 1
		elif n is CSGShape3D:
			totals["csg"] += 1
		elif n is Light3D:
			totals["lights"] += 1
			if (n as Light3D).shadow_enabled:
				totals["light_shadows"] += 1
		elif n is GPUParticles3D or n is CPUParticles3D:
			totals["particles"] += 1
		for c in n.get_children():
			_stack.append(c)

	var meshes := _sorted_entries(mesh_sig)
	var materials := _sorted_entries(material_sig)
	var result := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "render_manifest",
		"scene": _scene_of(root),
		"built": Time.get_datetime_string_from_system(true),
		"totals": totals,
		"classes": _sorted_dict(classes),
		"meshes": meshes,
		"materials": materials,
		"actions": _actions(totals, meshes, materials),
	}
	result["markdown"] = build_markdown(result, opts)
	result["estimated_tokens"] = estimate_tokens(String(result["markdown"]))
	return result


## headless / 编辑器都能用：从 .tscn 加载后构建。
static func build_from_scene_path(path: String, opts := {}) -> Dictionary:
	if path == "":
		return _empty("场景路径为空")
	var ps := load(path)
	if ps == null or not (ps is PackedScene):
		return _empty("无法加载场景：%s" % path)
	var inst := (ps as PackedScene).instantiate()
	if inst == null:
		return _empty("场景实例化失败：%s" % path)
	var res := build(inst, opts)
	inst.free()
	return res


static func _mesh_signature(mi: MeshInstance3D) -> String:
	var m := mi.mesh
	var path := ""
	if m != null and m.resource_path != "":
		path = m.resource_path.get_file()
	else:
		path = m.get_class()
	var surfaces := m.get_surface_count() if m != null else 0
	return "%s|%d|%d" % [path, surfaces, 1 if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else 0]


static func _material_signature(mi: MeshInstance3D) -> String:
	var mat := mi.get_active_material(0) if mi.mesh != null and mi.mesh.get_surface_count() > 0 else null
	if mat == null:
		return ""
	var path := mat.resource_path.get_file() if mat.resource_path != "" else mat.get_class()
	var kind := "opaque"
	if mat is BaseMaterial3D:
		var bm := mat as BaseMaterial3D
		if bm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or bm.albedo_color.a < 1.0:
			kind = "transparent"
		elif bm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
			kind = "unshaded"
	elif mat is ShaderMaterial:
		kind = "shader"
	return "%s:%s" % [kind, path]


static func _sorted_entries(counts: Dictionary) -> Array[Dictionary]:
	var arr: Array[Dictionary] = []
	for k in counts.keys():
		arr.append({"signature": String(k), "count": int(counts[k])})
	arr.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
	return arr


static func _sorted_dict(counts: Dictionary) -> Array[Dictionary]:
	var arr: Array[Dictionary] = []
	for k in counts.keys():
		arr.append({"class": String(k), "count": int(counts[k])})
	arr.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
	return arr


## 把事实翻译成「值得看的动作」，但不下结论（结论要交给实测）。
static func _actions(totals: Dictionary, meshes: Array[Dictionary], materials: Array[Dictionary]) -> Array[String]:
	var out: Array[String] = []
	if not meshes.is_empty() and int(meshes[0]["count"]) >= 20:
		out.append("同一网格出现 %d 次（`%s`）：可考虑 MultiMeshInstance3D 合并 draw call" % [
			int(meshes[0]["count"]), String(meshes[0]["signature"])])
	if int(totals["shadow_casters"]) > 0 and int(totals["shadow_casters"]) * 2 > int(totals["mesh_instances"]):
		out.append("投射阴影的网格实例占多数（%d / %d）：先确认是否都必要，装饰物通常可以关阴影" % [
			int(totals["shadow_casters"]), int(totals["mesh_instances"])])
	if int(totals["no_visibility_range"]) >= 20:
		out.append("有 %d 个网格实例既没有 visibility_range_begin 也没有 end：远景小物件可加可见距离" % int(totals["no_visibility_range"]))
	if int(totals["transparent_materials"]) > 0:
		out.append("有 %d 个网格使用透明/半透明材质：过度绘制（overdraw）的常见来源，注意叠层数量" % int(totals["transparent_materials"]))
	if int(totals["light_shadows"]) >= 3:
		out.append("%d 盏灯开了阴影：只保留主光/关键光投影通常已足够" % int(totals["light_shadows"]))
	if int(totals["csg"]) > 0:
		out.append("场景内有 %d 个 CSG 节点：CSG 在运行时做布尔运算，量产前建议烘焙成网格" % int(totals["csg"]))
	if int(totals["particles"]) >= 5:
		out.append("%d 个粒子系统：注意粒子数量与材质是否透明（两者叠加最容易吃掉 GPU 填充率）" % int(totals["particles"]))
	if out.is_empty():
		out.append("没有触发常见的静态风险特征；性能问题更可能来自脚本、物理或运行期加载，建议直接采集 .bhx")
	return out


static func build_markdown(manifest: Dictionary, opts := {}) -> String:
	var budget := int(opts.get("max_entries", MAX_INDIVIDUAL_ENTRIES))
	var totals: Dictionary = manifest.get("totals", {})
	var lines: Array[String] = []
	lines.append("# 渲染清单（静态）")
	lines.append("")
	lines.append("- 场景：`%s`" % String(manifest.get("scene", "?")))
	lines.append("- 节点总数：%d（Node3D %d）" % [int(totals.get("nodes", 0)), int(totals.get("node3d", 0))])
	lines.append("- 网格实例：%d（MultiMeshInstance3D %d，CSG %d）" % [
		int(totals.get("mesh_instances", 0)), int(totals.get("multimesh_instances", 0)), int(totals.get("csg", 0))])
	lines.append("- 灯：%d（开阴影 %d）；粒子系统：%d" % [
		int(totals.get("lights", 0)), int(totals.get("light_shadows", 0)), int(totals.get("particles", 0))])
	lines.append("- 投射阴影的网格：%d；透明材质使用次数：%d；无可见距离设置：%d" % [
		int(totals.get("shadow_casters", 0)), int(totals.get("transparent_materials", 0)),
		int(totals.get("no_visibility_range", 0))])
	lines.append("")
	var classes: Array = manifest.get("classes", [])
	if not classes.is_empty():
		lines.append("## 节点构成")
		lines.append("")
		lines.append("| 类 | 数量 |")
		lines.append("| --- | ---: |")
		for c in classes:
			if budget <= 0:
				break
			lines.append("| %s | %d |" % [String(c.get("class", "")), int(c.get("count", 0))])
			budget -= 1
		lines.append("")
	var meshes: Array = manifest.get("meshes", [])
	if not meshes.is_empty():
		lines.append("## 重复网格 TOP（MultiMesh 候选）")
		lines.append("")
		lines.append("| 网格签名 | 实例数 |")
		lines.append("| --- | ---: |")
		for i in mini(meshes.size(), maxi(1, budget)):
			var m: Dictionary = meshes[i]
			lines.append("| `%s` | %d |" % [String(m.get("signature", "")), int(m.get("count", 0))])
		lines.append("")
	var materials: Array = manifest.get("materials", [])
	if not materials.is_empty():
		lines.append("## 材质使用 TOP")
		lines.append("")
		lines.append("| 材质签名 | 次数 |")
		lines.append("| --- | ---: |")
		for i in mini(materials.size(), maxi(1, budget)):
			var m: Dictionary = materials[i]
			lines.append("| `%s` | %d |" % [String(m.get("signature", "")), int(m.get("count", 0))])
		lines.append("")
	var actions: Array = manifest.get("actions", [])
	if not actions.is_empty():
		lines.append("## 值得先确认的方向（不是结论，需实测）")
		lines.append("")
		for a in actions:
			lines.append("- %s" % String(a))
		lines.append("")
	return "\n".join(lines)


static func estimate_tokens(text: String) -> int:
	var ascii := 0
	var wide := 0
	for i in text.length():
		if text.unicode_at(i) < 128:
			ascii += 1
		else:
			wide += 1
	return int(ceil(float(ascii) / 4.0 + float(wide) / 1.5))


static func _scene_of(root: Node) -> String:
	if root == null:
		return ""
	if root.scene_file_path != "":
		return root.scene_file_path
	return String(root.name)


static func _empty(reason: String) -> Dictionary:
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "render_manifest",
		"error": reason,
		"totals": {},
		"classes": [],
		"meshes": [],
		"materials": [],
		"actions": [],
		"markdown": "# 渲染清单（静态）\n\n无法生成：%s\n" % reason,
		"estimated_tokens": 0,
	}

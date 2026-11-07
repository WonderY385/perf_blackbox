@tool
class_name BBCorrelate
extends RefCounted
## E2 静态 × 实测关联：把「事件里新冒出来的实体」和「场景清单里的静态事实」对上。
##
## 单项都不新鲜：.bhx 有实测差分，清单有静态构成。价值在**交叉**——
## 事件窗口新增了 200 个 MeshInstance3D，而清单指出「同一网格全场景出现 260 次」，
## 这两句放在一起才让人知道「该做 MultiMesh」还是「该做分帧实例化」。
##
## 这里只输出「可验证的假设 + 怎么验」，不输出「你该改第几行」。

## 允许做假设实验的属性白名单（设计文档 E2）——只改这些，改完能还原。
const EXPERIMENT_PROPERTIES := [
	"cast_shadow",
	"shadow_enabled",
	"visible",
	"visibility_range_begin",
	"visibility_range_end",
	"material_override",
	"transparency",
	"shading_mode",
]

const CONFIDENCE_BASE := 0.35
const CONFIDENCE_MESH_MATCH := 0.25
const CONFIDENCE_COUNTER_MATCH := 0.20
const CONFIDENCE_COUNT_SCALE := 0.20


## pack: .bhx 包；manifest: BBRenderManifest.build() 的结果。
static func correlate(pack: Dictionary, manifest: Dictionary) -> Dictionary:
	if pack.is_empty():
		return _empty("没有可用的 .bhx 包")
	if manifest.is_empty() or manifest.has("error"):
		return _empty("没有可用的渲染清单（先跑 BB.render_manifest()）")
	var deltas: Dictionary = pack.get("deltas", {})
	var events: Array = pack.get("events", [])
	var classes := {}
	for c in manifest.get("classes", []):
		classes[String(c.get("class", ""))] = int(c.get("count", 0))
	var meshes: Array = manifest.get("meshes", [])
	var top_mesh_count := 0
	var top_mesh_sig := ""
	if not meshes.is_empty():
		top_mesh_count = int((meshes[0] as Dictionary).get("count", 0))
		top_mesh_sig = String((meshes[0] as Dictionary).get("signature", ""))

	var hypotheses: Array[Dictionary] = []
	for ev in events:
		var ev_id := String((ev as Dictionary).get("id", ""))
		var d: Dictionary = deltas.get(ev_id, {})
		if d.is_empty():
			continue
		var entities: Array = d.get("entities", [])
		var counters: Array = d.get("counters", [])
		for ent in entities:
			var e: Dictionary = ent
			var key := String(e.get("key", ""))
			var kind := String(e.get("kind", ""))
			var added := int(e.get("added", 0))
			if added <= 0:
				continue
			var static_count := int(classes.get(key, 0))
			var tags: Array[String] = []
			var conf := CONFIDENCE_BASE
			var evidence: Array[String] = []
			if kind == "node_class" and static_count > 0:
				conf += CONFIDENCE_MESH_MATCH
				evidence.append("清单里 `%s` 共 %d 个，事件窗口新增 %d 个" % [key, static_count, added])
				if key == "MeshInstance3D" and top_mesh_count >= 20:
					conf += CONFIDENCE_MESH_MATCH
					tags.append("multimesh_candidate")
					evidence.append("重复网格 TOP1 `%s` 出现 %d 次" % [top_mesh_sig, top_mesh_count])
			elif kind == "node_class":
				evidence.append("事件窗口新增 %d 个 `%s`（清单里当前场景没有同类，可能是运行时实例化）" % [added, key])
			elif kind == "scene":
				tags.append("scene_load")
				evidence.append("事件窗口新增场景 `%s`" % key)
			# 计数证据：draw_calls / primitives 是否同步跳变
			for ctr in counters:
				var c: Dictionary = ctr
				var col := String(c.get("column", ""))
				if col in ["draw_calls", "primitives", "objects"]:
					var delta := float(c.get("delta", 0.0))
					if delta > 0.0:
						conf += CONFIDENCE_COUNTER_MATCH
						evidence.append("同期 `%s` 上升 %.1f（基线 %.1f → 峰值 %.1f）" % [
							col, delta, float(c.get("baseline", 0.0)), float(c.get("peak", 0.0))])
						if col == "draw_calls":
							tags.append("draw_call_spike")
						break
			conf += minf(float(added) / 200.0, 1.0) * CONFIDENCE_COUNT_SCALE
			conf = clampf(conf, 0.0, 0.98)
			hypotheses.append({
				"event_id": ev_id,
				"kind": kind,
				"key": key,
				"added": added,
				"static_count": static_count,
				"confidence": conf,
				"evidence": evidence,
				"tags": tags,
				"experiment": plan_experiment(kind, key, added),
			})
	hypotheses.sort_custom(func(a, b): return float(a["confidence"]) > float(b["confidence"]))
	var top := hypotheses.slice(0, 8) if hypotheses.size() > 8 else hypotheses
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "static_vs_measured",
		"scene": String(manifest.get("scene", "")),
		"events": events.size(),
		"hypotheses": top,
		"needs_more_data": top.is_empty(),
		"markdown": build_markdown(top, manifest),
	}


## 假设实验：怎么用最小改动验证这条假设（给出可执行的开关方案，而不是建议）。
static func plan_experiment(kind: String, key: String, added: int) -> Dictionary:
	var steps: Array[String] = []
	var allowed: Array[String] = []
	if kind == "node_class":
		if key == "MeshInstance3D" or key == "GeometryInstance3D":
			allowed = ["cast_shadow", "visibility_range_begin", "visibility_range_end"]
			steps.append("把这些实例的 `cast_shadow` 设为 `SHADOW_CASTING_SETTING_OFF`，同路线重测")
			steps.append("再给它们加 `visibility_range_end`（比如 60m），同路线重测")
			steps.append("如果两者都只是小幅改善，改用 MultiMeshInstance3D 合并后重测")
		elif key.contains("Light"):
			allowed = ["shadow_enabled"]
			steps.append("把新增灯的 `shadow_enabled` 关掉，同路线重测")
		elif key.contains("Particles"):
			allowed = ["visible"]
			steps.append("临时隐藏新增粒子系统，同路线重测（判断是不是填充率问题）")
		else:
			allowed = ["visible"]
			steps.append("临时隐藏这类节点（`visible=false`），同路线重测，确认它确实是主因")
	elif kind == "scene":
		allowed = ["visible"]
		steps.append("把该场景的实例化挪到加载阶段（或分帧实例化），再走同一路线")
		steps.append("对比两次采集的 `pipeline_delta` 与 `resource_count` 跳变")
	else:
		steps.append("先确认这条增量能稳定复现，再考虑开关实验")
	return {
		"allowed_properties": allowed,
		"steps": steps,
		"measure": {
			"method": "交错 A/B 重测",
			"rounds": 4,
			"warmup_s": 3.0,
			"sample_s": 5.0,
			"signal": "delta_ms 与 95%CI",
		},
		"verify_with": ["BB.measure_system()", "BB.regression()"],
	}


static func build_markdown(hypotheses: Array, manifest: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("# 静态清单 × 实测事件（关联假设）")
	lines.append("")
	lines.append("场景：`%s`" % String(manifest.get("scene", "?")))
	lines.append("")
	if hypotheses.is_empty():
		lines.append("没有可关联的假设：这次事件里没有「新出现的实体」类证据。")
		lines.append("")
		lines.append("下一步：给可疑函数加 `BBProbe.count()` 探针，或用 `BB.measure_system()` 做 A/B 重测。")
		lines.append("")
		return "\n".join(lines)
	lines.append("| 假设 | 置信 | 依据 |")
	lines.append("| --- | ---: | --- |")
	for h in hypotheses:
		var evidence: Array = h.get("evidence", [])
		lines.append("| %s / `%s` +%d | %.2f | %s |" % [
			String(h.get("kind", "")), String(h.get("key", "")), int(h.get("added", 0)),
			float(h.get("confidence", 0.0)),
			"；".join(evidence.slice(0, 2))])
	lines.append("")
	lines.append("## 最值得先验的一条")
	lines.append("")
	var top: Dictionary = hypotheses[0]
	var exp: Dictionary = top.get("experiment", {})
	lines.append("假设：事件 `%s` 窗口内新增 %d 个 `%s`，而清单显示场景里同类共 %d 个。" % [
		String(top.get("event_id", "")), int(top.get("added", 0)),
		String(top.get("key", "")), int(top.get("static_count", 0))])
	lines.append("")
	for s in exp.get("steps", []):
		lines.append("1. %s" % String(s))
	lines.append("")
	lines.append("可改属性白名单：%s" % ", ".join(PackedStringArray(exp.get("allowed_properties", []))))
	lines.append("")
	lines.append("> 这些是「怎么验」，不是「结论」。改完必须再采一包用 `BB.regression()` 对比，")
	lines.append("> 差值超过噪声底才算真的有效。")
	lines.append("")
	return "\n".join(lines)


static func _empty(reason: String) -> Dictionary:
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"kind": "static_vs_measured",
		"error": reason,
		"hypotheses": [],
		"needs_more_data": true,
		"markdown": "# 静态清单 × 实测事件\n\n无法关联：%s\n" % reason,
	}

@tool
class_name BBSystemMatrix
extends RefCounted
## D2 系统开关矩阵：把「启用这个系统/插件到底值几毫秒」测成一个带置信区间的数字。
##
## 为什么不能只跑两次：帧耗时自身的抖动远大于 1~2ms 的效应。所以：
##   1) 交错多轮 A/B/A/B，消除「越跑越热 / 越跑越卡」的系统性漂移
##   2) 每轮取 p95（不是均值——掉帧是极值现象）
##   3) 配对差分 d_i = B_i - A_i，再做 bootstrap 求 95%CI
##   4) 只有当 CI 下界也大于噪声底时，才敢说「显著」
##
## spec 支持三种开关：
##   {kind:"node",   target: NodePath|String|Node}  热开关：递归 process_mode/visible/physics
##   {kind:"group",  target: "enemies"}             热开关：整个 group
##   {kind:"custom", set_enabled: Callable(bool)}   自定义（例如插件的 feature flag）

const DEFAULT_OPTS := {
	"runs": 4,
	"warmup_s": 3.0,
	"sample_s": 5.0,
	"settle_frames": 30,
	"noise_ratio": 0.05,
	"noise_abs_ms": 0.1,
}


static func measure(tree: SceneTree, spec: Dictionary, opts := {}) -> Dictionary:
	var o := DEFAULT_OPTS.duplicate()
	for k in opts:
		o[k] = opts[k]
	var runs := maxi(1, int(o["runs"]))
	var name := String(spec.get("name", "unnamed"))
	var target = spec.get("target", null)
	var kind := String(spec.get("kind", "node"))

	var probe := _resolve_target(tree, kind, target, spec)
	if probe.has("error"):
		return _err(name, String(probe["error"]))

	# 帧内忙时间探针：帧首节点（priority 极小）+ 帧尾节点（priority 极大）。
	# 为什么要它：vsync / headless 会把帧间隔钉死（实测 headless 恒定 ~6.9ms），
	# 这时 2ms 的开销被「空闲睡眠」吸收，用墙钟 dt 根本测不出来。忙时间才反映真实 CPU 成本。
	var clock := _ClockHolder.new()
	var begin_node := _FrameBeginNode.new()
	begin_node.holder = clock
	begin_node.process_priority = -100000
	var end_node := _FrameEndNode.new()
	end_node.holder = clock
	end_node.process_priority = 100000
	tree.root.add_child(begin_node)
	tree.root.add_child(end_node)

	var pairs := PackedFloat64Array()      # 每轮 busy p95(on) - p95(off)：主指标
	var wall_pairs := PackedFloat64Array()
	var gpu_pairs := PackedFloat64Array()
	var cpu_pairs := PackedFloat64Array()
	var off_p95 := PackedFloat64Array()
	var on_p95 := PackedFloat64Array()
	var notes := PackedStringArray()
	var degraded := false

	var t_start := Time.get_ticks_usec()
	for r in runs:
		# A：关
		var a: Dictionary = await _switch_and_sample(tree, spec, kind, probe, false, o, notes, clock)
		if a.has("error"):
			begin_node.queue_free()
			end_node.queue_free()
			return _err(name, String(a["error"]))
		# B：开
		var b: Dictionary = await _switch_and_sample(tree, spec, kind, probe, true, o, notes, clock)
		if b.has("error"):
			begin_node.queue_free()
			end_node.queue_free()
			return _err(name, String(b["error"]))
		var pa := float(a["busy_med"])
		var pb := float(b["busy_med"])
		off_p95.append(pa)
		on_p95.append(pb)
		pairs.append(pb - pa)
		wall_pairs.append(float(b["frame_p95"]) - float(a["frame_p95"]))
		var ga := float(a["gpu_p95"])
		var gb := float(b["gpu_p95"])
		if ga >= 0.0 and gb >= 0.0:
			gpu_pairs.append(gb - ga)
		var ca := float(a["cpu_p95"])
		var cb := float(b["cpu_p95"])
		if ca >= 0.0 and cb >= 0.0:
			cpu_pairs.append(cb - ca)

	# 恢复初始状态（保险：即便中途异常也尽量还原）
	_set_enabled(spec, kind, probe, true)
	begin_node.queue_free()
	end_node.queue_free()

	var mean_off := BBStats.mean(off_p95)
	var mean_on := BBStats.mean(on_p95)
	var delta := BBStats.mean(pairs) if pairs.size() > 0 else 0.0
	var ci := BBStats.mean_ci(pairs, 1000, 0.95) if pairs.size() >= 2 else Vector2(delta, delta)
	var noise := maxf(absf(mean_off) * float(o["noise_ratio"]), float(o["noise_abs_ms"]))
	var sigma := BBStats.stdev(pairs)
	var min_detectable := 0.0
	if pairs.size() >= 2:
		min_detectable = 1.96 * sigma / sqrt(float(pairs.size()))
	var significant := pairs.size() >= 2 and ci.x > noise and delta > noise

	var out := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"system": name,
		"kind": kind,
		"runs": runs,
		"baseline_p95_ms": snappedf(mean_off, 0.01),
		"enabled_p95_ms": snappedf(mean_on, 0.01),
		"delta_ms": snappedf(delta, 0.01),
		"metric": "busy_med_ms",
		"frame_delta_ms": snappedf(BBStats.mean(wall_pairs), 0.01) if wall_pairs.size() > 0 else 0.0,
		"ci_low_ms": snappedf(ci.x, 0.01),
		"ci_high_ms": snappedf(ci.y, 0.01),
		"noise_floor_ms": snappedf(noise, 0.01),
		"min_detectable_ms": snappedf(min_detectable, 0.01),
		"significant": significant,
		"degraded": degraded,
		"rounds": _rounds_detail(off_p95, on_p95, pairs),
		"notes": notes,
		"elapsed_s": snappedf((Time.get_ticks_usec() - t_start) / 1000000.0, 0.1),
	}
	if gpu_pairs.size() >= 2:
		var gci := BBStats.mean_ci(gpu_pairs, 1000, 0.95)
		out["gpu_delta_ms"] = snappedf(BBStats.mean(gpu_pairs), 0.01)
		out["gpu_ci"] = [snappedf(gci.x, 0.01), snappedf(gci.y, 0.01)]
	else:
		out["gpu_delta_ms"] = -1.0
		notes.append("GPU 拆分不可用（headless 或渲染计时未启用）")
	if cpu_pairs.size() >= 2:
		var cci := BBStats.mean_ci(cpu_pairs, 1000, 0.95)
		out["cpu_delta_ms"] = snappedf(BBStats.mean(cpu_pairs), 0.01)
		out["cpu_ci"] = [snappedf(cci.x, 0.01), snappedf(cci.y, 0.01)]
	else:
		out["cpu_delta_ms"] = -1.0
	out["verdict"] = _verdict(out)
	return out


## 单轮：切开关 → 丢掉 settle_frames → 预热 → 按墙钟采样
static func _switch_and_sample(tree: SceneTree, spec: Dictionary, kind: String, probe: Dictionary, enable: bool, o: Dictionary, notes: PackedStringArray, clock: RefCounted = null) -> Dictionary:
	_set_enabled(spec, kind, probe, enable, notes)
	var settle := maxi(0, int(o["settle_frames"]))
	for i in settle:
		await tree.process_frame
	# 预热
	var warm_end := Time.get_ticks_usec() + int(float(o["warmup_s"]) * 1000000.0)
	while Time.get_ticks_usec() < warm_end:
		await tree.process_frame
	# 采样
	var frames := PackedFloat64Array()
	var busy := PackedFloat64Array()
	var gpus := PackedFloat64Array()
	var vp := tree.root.get_viewport()
	var gpu_ok := _gpu_available() and vp != null
	if gpu_ok:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	var last := Time.get_ticks_usec()
	var sample_end := last + int(float(o["sample_s"]) * 1000000.0)
	while true:
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var dt_ms := float(now - last) / 1000.0
		last = now
		if dt_ms > 0.0:
			frames.append(dt_ms)
			if clock != null and is_instance_valid(clock):
				var begin_us := int(clock.get("begin_us"))
				var end_us := int(clock.get("end_us"))
				if begin_us > 0 and end_us >= begin_us:
					busy.append(float(end_us - begin_us) / 1000.0)
			if gpu_ok:
				var g := RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
				if g >= 0.0:
					gpus.append(g)
		if now >= sample_end:
			break
	if gpu_ok:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), false)
	var frame_p95 := BBStats.percentile(frames, 0.95) if frames.size() > 0 else 0.0
	# 忙时间才是主指标；没有 clock 或采样太少时退回墙钟，并把口径写进结果
	var busy_p95 := BBStats.percentile(busy, 0.95) if busy.size() >= 30 else frame_p95
	# 主指标用中位数：CPU 忙时间比帧间隔稳定得多，p95 会被偶发尖刺带偏
	var busy_med := BBStats.median(busy) if busy.size() >= 30 else frame_p95
	var gpu_p95 := BBStats.percentile(gpus, 0.95) if gpus.size() >= 30 else -1.0
	return {
		"p95": busy_med,
		"busy_med": busy_med,
		"busy_p95": busy_p95,
		"frame_p95": frame_p95,
		"gpu_p95": gpu_p95,
		"cpu_p95": -1.0,
		"frames": frames.size(),
		"busy_samples": busy.size(),
	}


static func _set_enabled(spec: Dictionary, kind: String, probe: Dictionary, enable: bool, notes: PackedStringArray = PackedStringArray()) -> void:
	match kind:
		"custom":
			var cb: Callable = spec.get("set_enabled", Callable())
			if cb.is_valid():
				cb.call(enable)
		"group":
			var tree: SceneTree = probe.get("tree")
			if tree == null:
				return
			for n in tree.get_nodes_in_group(String(spec.get("target", ""))):
				_apply_node_state(n, enable)
		_:
			var node: Node = probe.get("node")
			if node == null or not is_instance_valid(node):
				return
			_apply_node_state(node, enable)


static func _apply_node_state(node: Node, enable: bool) -> void:
	if not is_instance_valid(node):
		return
	if enable:
		node.process_mode = Node.PROCESS_MODE_INHERIT
		node.set_physics_process(true)
		if node is CanvasItem:
			(node as CanvasItem).visible = true
		if node is Node3D:
			(node as Node3D).visible = true
	else:
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.set_physics_process(false)
		if node is CanvasItem:
			(node as CanvasItem).visible = false
		if node is Node3D:
			(node as Node3D).visible = false
	for c in node.get_children():
		_apply_node_state(c, enable)


static func _resolve_target(tree: SceneTree, kind: String, target, spec: Dictionary) -> Dictionary:
	match kind:
		"custom":
			var cb: Callable = spec.get("set_enabled", Callable())
			if not cb.is_valid():
				return {"error": "custom 系统必须提供 set_enabled Callable"}
			return {"tree": tree}
		"group":
			if String(target) == "":
				return {"error": "group 系统必须提供 target"}
			return {"tree": tree}
		_:
			var node: Node = null
			if target is Node:
				node = target
			elif target is NodePath or target is String:
				var p := str(target)
				if p.begins_with("/root/"):
					node = tree.root.get_node_or_null(p.substr(6))
				else:
					node = tree.root.get_node_or_null(p)
			if node == null:
				return {"error": "找不到目标节点：%s" % str(target)}
			if node == tree.root:
				return {"error": "不能对整个场景根做开关测量（会停掉记录器本身）"}
			return {"node": node}


static func _gpu_available() -> bool:
	return DisplayServer.get_name() != "headless"


static func _rounds_detail(off: PackedFloat64Array, on: PackedFloat64Array, pairs: PackedFloat64Array) -> Array:
	var out := []
	for i in mini(pairs.size(), mini(off.size(), on.size())):
		out.append({
			"round": i + 1,
			"off_p95": snappedf(off[i], 0.01),
			"on_p95": snappedf(on[i], 0.01),
			"d": snappedf(pairs[i], 0.01),
		})
	return out


static func _verdict(res: Dictionary) -> String:
	if bool(res.get("significant", false)):
		return "slower" if float(res["delta_ms"]) > 0.0 else "faster"
	if absf(float(res.get("delta_ms", 0.0))) <= float(res.get("noise_floor_ms", 0.1)):
		return "no_measurable_cost"
	return "needs_more_runs"


static func _err(name: String, msg: String) -> Dictionary:
	return {"schema_version": BBSchema.SCHEMA_VERSION, "system": name, "error": msg}


## 帧内忙时间的共享容器 + 帧首/帧尾节点。
## 忙时间 = 帧尾 - 帧首，天然排除 vsync / 空闲睡眠，是 D2 的主指标。
class _ClockHolder:
	extends RefCounted
	var begin_us := 0
	var end_us := 0


class _FrameBeginNode:
	extends Node
	var holder: RefCounted

	func _process(_delta: float) -> void:
		holder.set("begin_us", Time.get_ticks_usec())


class _FrameEndNode:
	extends Node
	var holder: RefCounted

	func _process(_delta: float) -> void:
		holder.set("end_us", Time.get_ticks_usec())
@tool
class_name BBPromptPack
extends RefCounted
## C2b 提示词包：给网页版 LLM 看（不要求用户装 MCP 客户端）。
## 分级压缩 L0/L1/L2：按 token 预算逐层裁剪，低预算也保留因果链骨架。

const DEFAULT_MAX_TOKENS := 2000
const TIMELINE_POINTS := 30


static func build(pack: Dictionary, opts := {}) -> String:
	var budget := int(opts.get("max_tokens", DEFAULT_MAX_TOKENS))
	var text := _build_tier(pack, 2)
	if estimate_tokens(text) <= budget:
		return text
	text = _build_tier(pack, 1)
	if estimate_tokens(text) <= budget:
		return text + "\n<!-- 已压缩至 L1，估计 ~%d tokens -->\n" % estimate_tokens(text)
	text = _build_tier(pack, 0)
	return text + "\n<!-- 已压缩至 L0，估计 ~%d tokens -->\n" % estimate_tokens(text)


static func _build_tier(pack: Dictionary, tier: int) -> String:
	var events: Array = pack.get("events", [])
	var deltas: Dictionary = pack.get("deltas", {})
	var m: Dictionary = pack.get("manifest", {})
	var engine: Dictionary = m.get("engine", {})
	var env: Dictionary = m.get("env", {})
	var pre: Dictionary = m.get("measure_preconditions", {})
	var out := PackedStringArray()

	out.append("# 角色")
	out.append("你是 Godot 4 的渲染/性能工程师。以下是我项目里一次掉帧事件的黑匣子证据。")
	out.append("")
	out.append("# 硬约束（违反即无效）")
	out.append("1. 只允许基于「证据」小节的信息下结论；每条结论必须引用 evidence_id，如 [evt_0001/e1]。")
	out.append("2. 不要断言未采集的项目（例如你没看到火焰图，就不要说「CPU 瓶颈在 X 函数内部」）。")
	out.append("3. 若证据不足以判断，输出 needs_more_data，并说明还缺什么、如何用 Perf Blackbox 采集。")
	out.append("4. 区分「已观测事实」与「假设」；假设必须给出可执行的验证方法。")
	out.append("")

	out.append("# 项目背景")
	out.append("引擎 %s / 渲染器 %s / 驱动 %s / 物理 %s / %s" % [
		String(engine.get("version", "?")), String(engine.get("renderer", "?")),
		String(engine.get("driver", "?")), String(engine.get("physics", "?")),
		String(env.get("gpu", "?"))])
	out.append("v-sync=%s, max_fps=%s, headless=%s" % [
		pre.get("vsync", "?"), pre.get("max_fps", "?"), pre.get("headless", "?")])
	out.append("")

	if events.is_empty():
		out.append("# 事件")
		out.append("本次录制没有检测到掉帧事件（帧时间在阈值内）。请基于基线数据回答：帧时间分布如何、有无明显的异常列。")
		out.append("")
		out.append("# 期望输出（严格 JSON，不要输出别的）")
		out.append(JSON.stringify({
			"root_cause": "none_observed",
			"evidence_ids": [],
			"confidence": 0.0,
			"verified_facts": [],
			"hypotheses": [],
			"next_experiment": "",
		}, "  "))
		return "\n".join(out)

	var worst: Dictionary = events[0]
	for ev in events:
		if float(ev.get("peak_ms", 0.0)) > float(worst.get("peak_ms", 0.0)):
			worst = ev

	out.append("# 事件")
	out.append("共 %d 个事件，最严重的是 %s。" % [events.size(), String(worst.get("id", "?"))])
	out.append("")

	if tier >= 1:
		out.append("## 事件总表")
		for ev in events:
			var tags := "-"
			var ev_tags: Array = ev.get("tags", [])
			if not ev_tags.is_empty():
				tags = ",".join(PackedStringArray(ev_tags))
			out.append("- %s: peak %.1fms (baseline %.1fms, %.1fx) frames %d→%d severity=%s tags=%s" % [
				String(ev.get("id", "?")), float(ev.get("peak_ms", 0.0)), float(ev.get("baseline_ms", 0.0)),
				float(ev.get("ratio", 0.0)), int(ev.get("start_frame", 0)), int(ev.get("end_frame", 0)),
				String(ev.get("severity", "?")), tags])
		out.append("")

	var shown: Array = [worst] if tier == 0 else events
	for ev in shown:
		var d: Dictionary = deltas.get(String(ev.get("id", "")), {})
		out.append("## %s 的证据" % String(ev.get("id", "?")))
		var win: Array = ev.get("window", [0, 0])
		var base_win: Array = ev.get("baseline_window", [0, 0])
		out.append("- 窗口 %d→%d，基线窗口 %d→%d，峰值帧 %d" % [
			int(win[0]), int(win[1]), int(base_win[0]), int(base_win[1]), int(ev.get("peak_frame", -1))])
		if ev.get("bookmark") != null:
			out.append("- 用户书签：%s" % String(ev.get("bookmark", "")))
		out.append("- 时间线（抽稀，* 为峰值帧）：`%s`" % _timeline(pack, ev))
		out.append("")

		var ranked: Array = d.get("ranking", [])
		if ranked.is_empty():
			out.append("候选：无（窗口内没有显著新增信号）")
			out.append("")
		else:
			out.append("候选（相对基线的新增信号）：")
			var limit := 8 if tier >= 2 else 4
			for r in ranked.slice(0, limit):
				out.append("- [%s/%s] %s  score=%.2f  baseline_present=%s" % [
					String(ev.get("id", "?")), ",".join(PackedStringArray(r.get("evidence", []))),
					String(r.get("cause", "?")), float(r.get("score", 0.0)),
					"true" if bool(r.get("baseline_present", false)) else "false"])
			out.append("")

		var excluded: Array = d.get("excluded", [])
		if tier >= 2 and not excluded.is_empty():
			var names: Array[String] = []
			for x in excluded.slice(0, 6):
				names.append(String(x.get("cause", "?")))
			out.append("已排除（基线里一直存在）：%s" % "; ".join(names))
			out.append("")
		var notes: Array = d.get("notes", [])
		if not notes.is_empty():
			for n in notes:
				out.append("注：%s" % String(n))
			out.append("")

	if tier >= 2:
		out.append("## 数值摘要（供参考，不要逐行复述）")
		out.append("frame_ms: %s" % _summary_line(pack))
		out.append("")

	out.append("# 期望输出（严格 JSON，不要输出别的）")
	out.append(JSON.stringify({
		"root_cause": "...",
		"evidence_ids": ["evt_0001/e1"],
		"confidence": 0.0,
		"verified_facts": ["..."],
		"hypotheses": [{"claim": "...", "why": "...", "verify": "..."}],
		"next_experiment": "...",
	}, "  "))
	return "\n".join(out)


static func _timeline(pack: Dictionary, ev: Dictionary) -> String:
	var win: Array = ev.get("window", [0, 0])
	var from_frame := int(win[0])
	var to_frame := int(win[1])
	var data: Dictionary = pack.get("data", {})
	if not data.has("frame_ms"):
		return "(无逐帧数据)"
	var col: PackedFloat64Array = data["frame_ms"]
	var start_abs := int(pack.get("start_frame", 0))
	var i0 := maxi(0, from_frame - start_abs)
	var i1 := mini(col.size() - 1, to_frame - start_abs)
	if i1 < i0:
		return "(无逐帧数据)"
	var series := col.slice(i0, i1 + 1)
	var step := maxi(1, series.size() / TIMELINE_POINTS)
	var peak_frame := int(ev.get("peak_frame", -1))
	var parts := PackedStringArray()
	for i in range(0, series.size(), step):
		var v := series[i]
		if v < 0.0:
			continue
		var marker := "*" if from_frame + i == peak_frame else ""
		parts.append("f%d:%.1f%s" % [from_frame + i, v, marker])
	return " ".join(parts)


static func _summary_line(pack: Dictionary) -> String:
	var data: Dictionary = pack.get("data", {})
	if not data.has("frame_ms"):
		return "(无数据)"
	var col: PackedFloat64Array = data["frame_ms"]
	var clean := PackedFloat64Array()
	for v in col:
		if v >= 0.0:
			clean.append(v)
	if clean.is_empty():
		return "(无数据)"
	return "min %.1f / median %.1f / p95 %.1f / max %.1f (ms)" % [
		BBStats.percentile(clean, 0.0), BBStats.median(clean),
		BBStats.percentile(clean, 0.95), BBStats.max_value(clean)]


## 保守 token 估算：ASCII ≈ 4 chars/token，CJK ≈ 1.5 chars/token
static func estimate_tokens(text: String) -> int:
	var ascii := 0
	var cjk := 0
	for i in text.length():
		var c := text.unicode_at(i)
		if c < 128:
			ascii += 1
		else:
			cjk += 1
	return int(ceil(float(ascii) / 4.0 + float(cjk) / 1.5))

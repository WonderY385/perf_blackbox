@tool
class_name BBRegression
extends RefCounted
## D3 跨运行 / 跨提交回归。
##
## 和 `BB.compare()` 的区别：compare 只回答「这两段帧时间谁快」；回归要回答
## 「这次改动让哪些事件变多了、哪些消失了、环境是否可比、CI 该不该挂」。
##
## 原则：
## 1. **环境不可比就只给绝对数值**，不硬算百分比（不同 GPU 之间比 p95 是自欺欺人）。
## 2. 事件配对用「归因指纹」而不是 id（id 每次采集都会重排）。
## 3. 结论必须带噪声底：差值小于噪声底一律 unchanged。

const PASS_EXIT := 0
const REGRESSION_EXIT := 2
const DEFAULT_NOISE_RATIO := 0.05
const DEFAULT_NOISE_ABS_MS := 0.1

## 参与可比性判断的 manifest 字段（缺一个就算不可比）
const ENV_FIELDS := ["settings_hash", "vsync", "max_fps", "headless"]


static func compare(a: Dictionary, b: Dictionary, opts := {}) -> Dictionary:
	if a.is_empty() or b.is_empty():
		return {"schema_version": BBSchema.SCHEMA_VERSION, "error": "regression_needs_two_packs"}
	var env := env_compatibility(a, b)
	var frame := frame_stats(a, b, opts)
	var events := pair_events(a, b)
	var noise: float = frame["noise_floor_ms"]
	var delta: float = frame["delta_p95_ms"]
	var verdict := "unchanged"
	if env["compatible"]:
		if delta > noise:
			verdict = "regression"
		elif delta < -noise:
			verdict = "improvement"
	else:
		verdict = "not_comparable"
	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"compatible": env["compatible"],
		"env": env,
		"frame": frame,
		"events": events,
		"verdict": verdict,
		"exit_code": (REGRESSION_EXIT if verdict == "regression" else PASS_EXIT),
		"notes": _notes(env, frame, events, verdict),
	}


## 环境可比性：版本/渲染器/驱动/物理/vsync/限帧/headless 全部一致才算可比。
static func env_compatibility(a: Dictionary, b: Dictionary) -> Dictionary:
	var ma: Dictionary = a.get("manifest", {})
	var mb: Dictionary = b.get("manifest", {})
	var diffs: Array[String] = []
	for field in ENV_FIELDS:
		var va = ma.get(field)
		var vb = mb.get(field)
		if field == "settings_hash":
			# settings_hash 缺失时退化为逐字段比较 engine/env
			if va == null or vb == null:
				var ea: Dictionary = ma.get("engine", {})
				var eb: Dictionary = mb.get("engine", {})
				var eva: Dictionary = ma.get("env", {})
				var evb: Dictionary = mb.get("env", {})
				for k in ["version", "renderer", "physics_engine"]:
					if String(ea.get(k, "")) != String(eb.get(k, "")):
						diffs.append("engine.%s" % k)
				for k in ["os", "gpu", "driver"]:
					if String(eva.get(k, "")) != String(evb.get(k, "")):
						diffs.append("env.%s" % k)
				continue
		if String(str(va)) != String(str(vb)):
			diffs.append(field)
	var ea2: Dictionary = ma.get("engine", {})
	var eb2: Dictionary = mb.get("engine", {})
	if String(ea2.get("version", "")) != String(eb2.get("version", "")):
		if not diffs.has("engine.version"):
			diffs.append("engine.version")
	return {
		"compatible": diffs.is_empty(),
		"diffs": diffs,
		"reason": ("环境一致，可以按百分比比较" if diffs.is_empty()
			else "以下项不一致，只给绝对数值：%s" % ", ".join(diffs)),
	}


## 帧时间统计：中位数/p95/p99/最大值 + 差值 + 噪声底。
static func frame_stats(a: Dictionary, b: Dictionary, opts := {}) -> Dictionary:
	var ratio := float(opts.get("noise_ratio", DEFAULT_NOISE_RATIO))
	var abs_ms := float(opts.get("noise_abs_ms", DEFAULT_NOISE_ABS_MS))
	var sa := _summary(a)
	var sb := _summary(b)
	var noise := maxf(float(sa["p50"]) * ratio, abs_ms)
	return {
		"baseline": sa,
		"current": sb,
		"delta_p50_ms": float(sb["p50"]) - float(sa["p50"]),
		"delta_p95_ms": float(sb["p95"]) - float(sa["p95"]),
		"delta_max_ms": float(sb["max"]) - float(sa["max"]),
		"noise_floor_ms": noise,
		"noise_ratio": ratio,
		"noise_abs_ms": abs_ms,
	}


static func _summary(pack: Dictionary) -> Dictionary:
	var vals := _column(pack, "frame_ms")
	if vals.is_empty():
		return {"p50": -1.0, "p95": -1.0, "p99": -1.0, "max": -1.0, "frames": 0}
	var clean := PackedFloat64Array()
	for v in vals:
		if v >= 0.0:
			clean.append(v)
	if clean.is_empty():
		return {"p50": -1.0, "p95": -1.0, "p99": -1.0, "max": -1.0, "frames": 0}
	return {
		"p50": BBStats.median(clean),
		"p95": BBStats.percentile(clean, 0.95),
		"p99": BBStats.percentile(clean, 0.99),
		"max": BBStats.percentile(clean, 0.999),
		"frames": clean.size(),
	}


static func _column(pack: Dictionary, col: String) -> PackedFloat64Array:
	var data: Dictionary = pack.get("data", {})
	var v = data.get(col)
	if v is PackedFloat64Array:
		return v
	if v is Array:
		return PackedFloat64Array(v)
	return PackedFloat64Array()


## 事件配对：用「归因指纹」= 分级 + 首要归因 + 取整倍数。
static func pair_events(a: Dictionary, b: Dictionary) -> Dictionary:
	var ea: Array = a.get("events", [])
	var eb: Array = b.get("events", [])
	var da: Dictionary = a.get("deltas", {})
	var db: Dictionary = b.get("deltas", {})

	var used_a := {}
	var matched: Array[Dictionary] = []
	var added: Array[Dictionary] = []
	for ev_b in eb:
		var fp_b := fingerprint(ev_b, db)
		var found := -1
		for i in ea.size():
			if used_a.has(i):
				continue
			if fingerprint(ea[i], da) == fp_b:
				found = i
				break
		if found >= 0:
			used_a[found] = true
			matched.append({
				"fingerprint": fp_b,
				"baseline": _ev_brief(ea[found]),
				"current": _ev_brief(ev_b),
				"delta_peak_ms": float(ev_b.get("peak_ms", 0.0)) - float(ea[found].get("peak_ms", 0.0)),
			})
		else:
			added.append(_ev_brief(ev_b))
	var disappeared: Array[Dictionary] = []
	for i in ea.size():
		if not used_a.has(i):
			disappeared.append(_ev_brief(ea[i]))
	return {
		"baseline_count": ea.size(),
		"current_count": eb.size(),
		"matched": matched,
		"added": added,
		"disappeared": disappeared,
	}


static func fingerprint(ev: Dictionary, deltas: Dictionary) -> String:
	var sev := String(ev.get("severity", ""))
	var top := "none"
	var d = deltas.get(String(ev.get("id", "")), {})
	if d is Dictionary and not d.is_empty():
		var ranked: Array = d.get("ranked", [])
		if not ranked.is_empty() and ranked[0] is Dictionary:
			top = String(ranked[0].get("cause", "none"))
	var ratio := float(ev.get("ratio", 1.0))
	return "%s|%s|%d" % [sev, top, int(round(ratio * 10.0))]


static func _ev_brief(ev: Dictionary) -> Dictionary:
	return {
		"id": String(ev.get("id", "")),
		"peak_frame": int(ev.get("peak_frame", -1)),
		"peak_ms": float(ev.get("peak_ms", -1.0)),
		"baseline_ms": float(ev.get("baseline_ms", -1.0)),
		"ratio": float(ev.get("ratio", 0.0)),
		"severity": String(ev.get("severity", "")),
		"tags": ev.get("tags", []),
	}


static func _notes(env: Dictionary, frame: Dictionary, events: Dictionary, verdict: String) -> Array[String]:
	var out: Array[String] = []
	if not bool(env["compatible"]):
		out.append(String(env["reason"]))
	out.append("事件：基线 %d 个，当前 %d 个；配对 %d，新增 %d，消失 %d" % [
		int(events["baseline_count"]), int(events["current_count"]),
		(events["matched"] as Array).size(),
		(events["added"] as Array).size(),
		(events["disappeared"] as Array).size(),
	])
	match verdict:
		"regression":
			out.append("p95 变慢 %.2f ms，超过噪声底 %.2f ms" % [
				float(frame["delta_p95_ms"]), float(frame["noise_floor_ms"])])
		"improvement":
			out.append("p95 变快 %.2f ms，超过噪声底 %.2f ms" % [
				-float(frame["delta_p95_ms"]), float(frame["noise_floor_ms"])])
		"unchanged":
			out.append("差值在噪声底以内（%.2f ms），判 unchanged" % float(frame["noise_floor_ms"]))
	return out


## 回归报告（Markdown）：给人和 CI 日志看。
static func build_md(result: Dictionary, opts := {}) -> String:
	if result.has("error"):
		return "# 回归失败\n\n%s\n" % String(result["error"])
	var label_a := String(opts.get("baseline_label", "基线"))
	var label_b := String(opts.get("current_label", "当前"))
	var env: Dictionary = result.get("env", {})
	var frame: Dictionary = result.get("frame", {})
	var events: Dictionary = result.get("events", {})
	var fa: Dictionary = frame.get("baseline", {})
	var fb: Dictionary = frame.get("current", {})

	var lines: Array[String] = []
	lines.append("# 性能回归报告")
	lines.append("")
	lines.append("**结论：%s**（退出码 %d）" % [_verdict_zh(String(result.get("verdict", ""))), int(result.get("exit_code", 0))])
	lines.append("")
	lines.append("环境可比性：%s" % ("✅ 一致" if bool(env.get("compatible", false)) else "⚠️ 不可比"))
	if not bool(env.get("compatible", false)):
		lines.append("")
		lines.append("> %s" % String(env.get("reason", "")))
	lines.append("")
	lines.append("## 帧时间")
	lines.append("")
	lines.append("| 指标 | %s | %s | 差值 |" % [label_a, label_b])
	lines.append("| --- | ---: | ---: | ---: |")
	for key in ["p50", "p95", "p99", "max"]:
		lines.append("| %s | %.2f ms | %.2f ms | %+.2f ms |" % [
			key, float(fa.get(key, -1.0)), float(fb.get(key, -1.0)),
			float(fb.get(key, 0.0)) - float(fa.get(key, 0.0))])
	lines.append("")
	lines.append("噪声底：`%.2f ms`（基线 p50 的 %.0f%% 与 %.1f ms 取大）" % [
		float(frame.get("noise_floor_ms", 0.0)),
		float(frame.get("noise_ratio", 0.05)) * 100.0,
		float(frame.get("noise_abs_ms", 0.1))])
	lines.append("")
	lines.append("## 事件变化")
	lines.append("")
	lines.append("| | %s | %s |" % [label_a, label_b])
	lines.append("| --- | ---: | ---: |")
	lines.append("| 事件数 | %d | %d |" % [int(events.get("baseline_count", 0)), int(events.get("current_count", 0))])
	lines.append("| 配对 | %d | |" % (events.get("matched", []) as Array).size())
	lines.append("")
	var added: Array = events.get("added", [])
	if not added.is_empty():
		lines.append("### 🆕 新出现的事件（这次改动可能引入的）")
		lines.append("")
		lines.append("| id | 峰值帧 | 峰值 ms | 倍数 | 分级 |")
		lines.append("| --- | ---: | ---: | ---: | --- |")
		for ev in added:
			lines.append("| %s | %d | %.2f | %.2fx | %s |" % [
				String(ev.get("id", "")), int(ev.get("peak_frame", -1)),
				float(ev.get("peak_ms", -1.0)), float(ev.get("ratio", 0.0)),
				String(ev.get("severity", ""))])
		lines.append("")
	var gone: Array = events.get("disappeared", [])
	if not gone.is_empty():
		lines.append("### ✅ 消失的事件（这次改动可能修好的）")
		lines.append("")
		lines.append("| id | 峰值帧 | 峰值 ms | 倍数 | 分级 |")
		lines.append("| --- | ---: | ---: | ---: | --- |")
		for ev in gone:
			lines.append("| %s | %d | %.2f | %.2fx | %s |" % [
				String(ev.get("id", "")), int(ev.get("peak_frame", -1)),
				float(ev.get("peak_ms", -1.0)), float(ev.get("ratio", 0.0)),
				String(ev.get("severity", ""))])
		lines.append("")
	var matched: Array = events.get("matched", [])
	if not matched.is_empty():
		lines.append("### 配对事件（同一类问题，看峰值是变好还是变坏）")
		lines.append("")
		lines.append("| 指纹 | %s 峰值 | %s 峰值 | 差 |" % [label_a, label_b])
		lines.append("| --- | ---: | ---: | ---: |")
		for m in matched:
			lines.append("| `%s` | %.2f ms | %.2f ms | %+.2f ms |" % [
				String(m.get("fingerprint", "")),
				float((m.get("baseline", {}) as Dictionary).get("peak_ms", -1.0)),
				float((m.get("current", {}) as Dictionary).get("peak_ms", -1.0)),
				float(m.get("delta_peak_ms", 0.0))])
		lines.append("")
	lines.append("## 说明")
	lines.append("")
	for n in result.get("notes", []):
		lines.append("- %s" % String(n))
	lines.append("")
	return "\n".join(lines)


static func _verdict_zh(v: String) -> String:
	match v:
		"regression":
			return "🔴 回归（变慢）"
		"improvement":
			return "🟢 改善（变快）"
		"unchanged":
			return "⚪ 无明显变化"
		"not_comparable":
			return "⚠️ 环境不可比（只看绝对数值）"
	return v

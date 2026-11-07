@tool
class_name BBCauseRanker
extends RefCounted
## B4 因果排序与反证：把三类 delta 统一成候选，按可解释加权和打分，输出 top-8 + 排除项。
## 原则：诚实说「不知道」> 编一个原因。

const WEIGHT_Z := 0.35
const WEIGHT_FIRST_SEEN := 0.30
const WEIGHT_MAGNITUDE := 0.20
const WEIGHT_STATIC_PRIOR := 0.10
const PENALTY_BASELINE := 0.25
const PENALTY_LOW_CONF := 0.20

const TAU := 8.0
const MAX_RANKED := 8
const INCONCLUSIVE_SCORE := 0.35

## 来源特异性先验：越靠近代码层的证据越可操作（脚本能直接改，实体数量只是结果）
## 没有 E1 静态知识时，这就是 static_prior 的唯一来源；后续 E2 会用它覆盖。
const PRIOR_SCRIPT := 1.0
const PRIOR_COUNTER := 0.6
const PRIOR_ENTITY := 0.4


static func rank(deltas: Dictionary, context: Dictionary) -> Dictionary:
	var peak_frame := int(context.get("peak_frame", -1))
	var low_conf := bool(context.get("low_confidence", false))

	var candidates: Array[Dictionary] = []
	var max_mag := {"script": 1.0, "entity": 1.0, "counter": 1.0}

	for s in deltas.get("scripts", []):
		max_mag["script"] = maxf(max_mag["script"], absf(float(s.get("delta", 0.0))))
	for e in deltas.get("entities", []):
		max_mag["entity"] = maxf(max_mag["entity"], absf(float(e.get("added", 0))))
	for c in deltas.get("counters", []):
		max_mag["counter"] = maxf(max_mag["counter"], absf(float(c.get("delta", 0.0))))

	for s in deltas.get("scripts", []):
		var first := int(s.get("first_seen_frame", -1))
		candidates.append({
			"cause": "script:%s（调用 %d，基线 %d）" % [s.get("id", "?"), int(s.get("calls", 0)), int(s.get("baseline_calls", 0))],
			"source": "script",
			"z_n": clampf(float(s.get("z", 0.0)) / 5.0, 0.0, 1.0),
			"fs_bonus": _first_seen_bonus(first, peak_frame),
			"mag_n": clampf(absf(float(s.get("delta", 0.0))) / max_mag["script"], 0.0, 1.0),
			"static_prior": PRIOR_SCRIPT,
			"in_baseline": bool(s.get("in_baseline", false)),
			"evidence_key": "script:%s" % s.get("id", "?"),
			"detail": s,
		})

	for e in deltas.get("entities", []):
		var first2 := int(e.get("first_seen_frame", -1))
		var label := "%s ×%d" % [e.get("key", "?"), int(e.get("added", 0))]
		if String(e.get("kind", "")) == "scene":
			label = "scene %s（+%d 节点）" % [e.get("key", "?"), int(e.get("added", 0))]
		candidates.append({
			"cause": "entity:%s" % label,
			"source": "entity",
			"z_n": clampf(float(e.get("added", 0)) / 60.0, 0.0, 1.0),
			"fs_bonus": _first_seen_bonus(first2, peak_frame),
			"mag_n": clampf(absf(float(e.get("added", 0))) / max_mag["entity"], 0.0, 1.0),
			"static_prior": PRIOR_ENTITY,
			"in_baseline": bool(e.get("in_baseline", false)),
			"evidence_key": "entity:%s:%s" % [e.get("kind", ""), e.get("key", "")],
			"detail": e,
		})

	for c in deltas.get("counters", []):
		var first3 := int(c.get("first_change_frame", -1))
		candidates.append({
			"cause": "counter:%s %+0.1f（基线 %0.1f → 峰值 %0.1f）" % [
				c.get("key", "?"), float(c.get("delta", 0.0)), float(c.get("baseline", 0.0)), float(c.get("peak", 0.0))],
			"source": "counter",
			"z_n": clampf(float(c.get("z", 0.0)) / 5.0, 0.0, 1.0),
			"fs_bonus": _first_seen_bonus(first3, peak_frame),
			"mag_n": clampf(absf(float(c.get("delta", 0.0))) / max_mag["counter"], 0.0, 1.0),
			"static_prior": PRIOR_COUNTER,
			"in_baseline": true,
			"evidence_key": "counter:%s" % c.get("key", "?"),
			"detail": c,
		})

	var ranking: Array[Dictionary] = []
	var excluded: Array[Dictionary] = []
	var evidence_seq := 0

	candidates.sort_custom(func(a, b): return _score(a, low_conf) > _score(b, low_conf))

	for cand in candidates:
		var score := _score(cand, low_conf)
		if bool(cand["in_baseline"]) and cand["source"] != "counter":
			excluded.append({
				"cause": cand["cause"],
				"reason": "基线窗口内同样活跃（不是「新出现」），已降权排除",
				"score": snappedf(score, 0.01),
			})
			continue
		if score <= 0.02:
			excluded.append({
				"cause": cand["cause"],
				"reason": "信号过弱（低于噪声底），不足以作为候选",
				"score": snappedf(score, 0.01),
			})
			continue
		evidence_seq += 1
		var entry := {
			"rank": ranking.size() + 1,
			"cause": cand["cause"],
			"source": cand["source"],
			"score": snappedf(score, 0.01),
			"evidence": ["e%d" % evidence_seq],
			"evidence_key": cand["evidence_key"],
			"baseline_present": bool(cand["in_baseline"]),
		}
		if ranking.size() < MAX_RANKED:
			ranking.append(entry)
		else:
			excluded.append({
				"cause": cand["cause"],
				"reason": "已超出 top-%d，合并进「其他候选」" % MAX_RANKED,
				"score": snappedf(score, 0.01),
			})

	var top_score := float(ranking[0]["score"]) if not ranking.is_empty() else 0.0
	var second := float(ranking[1]["score"]) if ranking.size() > 1 else 0.0
	var confident := top_score >= INCONCLUSIVE_SCORE and (ranking.size() == 1 or top_score - second >= 0.05)

	return {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"root_cause": "inconclusive" if not confident else String(ranking[0]["cause"]),
		"confidence": snappedf(top_score, 0.01),
		"ranked": ranking,
		"excluded": excluded,
		"notes": _notes(confident, ranking, low_conf, context),
	}


static func _score(cand: Dictionary, low_conf: bool) -> float:
	var s := WEIGHT_Z * float(cand["z_n"])
	s += WEIGHT_FIRST_SEEN * float(cand["fs_bonus"])
	s += WEIGHT_MAGNITUDE * float(cand["mag_n"])
	s += WEIGHT_STATIC_PRIOR * float(cand.get("static_prior", 0.0))
	if bool(cand["in_baseline"]):
		s -= PENALTY_BASELINE
	if low_conf:
		s -= PENALTY_LOW_CONF
	return s


static func _first_seen_bonus(first_frame: int, peak_frame: int) -> float:
	if first_frame < 0 or peak_frame < 0:
		return 0.0
	return exp(-absf(float(first_frame - peak_frame)) / TAU)


static func _notes(confident: bool, ranking: Array[Dictionary], low_conf: bool, context: Dictionary) -> Array[String]:
	var notes: Array[String] = []
	if not confident:
		notes.append("证据不足以锁定单一原因（最高分 < %.2f 或与第二名差距过小），结论标为 inconclusive。" % INCONCLUSIVE_SCORE)
		notes.append("建议：开启探针计时模式（probe=time）、延长录制、或用系统 A/B 实验验证。")
	if low_conf:
		notes.append("本次采集存在降级/不可用数据源，置信度已下调，详见 diagnostics。")
	if ranking.is_empty():
		notes.append("窗口内没有出现显著的新增信号：可能是纯 GPU 抖动、外部干扰，或事件被判错。")
	var unavailable: Array = context.get("unavailable", [])
	if not unavailable.is_empty():
		notes.append("以下数据源不可用：%s" % ", ".join(unavailable))
	return notes

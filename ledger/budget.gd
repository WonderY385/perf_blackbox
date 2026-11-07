@tool
class_name BBBudget
extends RefCounted
## D1 场景预算与基线：回答「这张图 60fps 到底危不危险」「昨天还好，今天怎么掉到 45 了」。
##
## 统计口径固定写进结果（否则不可比）：
##   - 去掉前 2 秒预热（加载/编译噪声）
##   - p50 / p95 / p99 取全部剩余帧
##   - max 取 p99.9，避免单帧异常把结论带偏
##   - 少于 MIN_FRAMES 帧时标 insufficient，不给结论

const WARMUP_MS := 2000.0
const MIN_FRAMES := 300
const DRIFT_PASS := 0.03   # 3% 内视为噪声
const DRIFT_WARN := 0.10   # 10% 内 WARN
const BASELINE_DIR := "res://.perf_blackbox/baselines"


## 从一份 pack 里算统计摘要（纯函数，无 I/O）
static func summarize(pack: Dictionary, warmup_ms := WARMUP_MS) -> Dictionary:
	var data: Dictionary = pack.get("data", {})
	var frames: PackedFloat64Array = data.get("frame_ms", PackedFloat64Array())
	var t_col: PackedFloat64Array = data.get("t_us", PackedFloat64Array())
	var start_us := 0.0
	if t_col.size() > 0:
		start_us = t_col[0]
	var warmup_us := warmup_ms * 1000.0
	var used := PackedFloat64Array()
	for i in frames.size():
		var v := frames[i]
		if v < 0.0:
			continue
		if t_col.size() > i and (t_col[i] - start_us) < warmup_us:
			continue
		used.append(v)
	var out := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"scene": _scene_of(pack),
		"frames_total": frames.size(),
		"frames_used": used.size(),
		"warmup_ms": warmup_ms,
		"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0,
		"state": "insufficient",
		"notes": [],
	}
	if used.size() < MIN_FRAMES:
		out["notes"].append("有效帧仅 %d（< %d），样本不足，不判定预算" % [used.size(), MIN_FRAMES])
		if used.size() > 0:
			out["p50"] = snappedf(BBStats.percentile(used, 0.50), 0.01)
			out["p95"] = snappedf(BBStats.percentile(used, 0.95), 0.01)
		return out
	out["p50"] = snappedf(BBStats.percentile(used, 0.50), 0.01)
	out["p95"] = snappedf(BBStats.percentile(used, 0.95), 0.01)
	out["p99"] = snappedf(BBStats.percentile(used, 0.99), 0.01)
	out["max"] = snappedf(BBStats.percentile(used, 0.999), 0.01)
	out["state"] = "no_budget"
	return out


## 在摘要基础上判定 PASS / WARN / FAIL
## budget: {"p95": float, "max": float}（<=0 视为未设置）
static func evaluate(summary: Dictionary, budget: Dictionary, baseline: Dictionary = {}) -> Dictionary:
	var out := summary.duplicate(true)
	var p95 := float(summary.get("p95", 0.0))
	var p99 := float(summary.get("p99", 0.0))
	var mx := float(summary.get("max", 0.0))
	var budget_p95 := float(budget.get("p95", 0.0))
	var budget_max := float(budget.get("max", 0.0))
	out["budget"] = {"p95": budget_p95, "max": budget_max}
	out["drift"] = 0.0
	out["baseline"] = baseline

	if String(summary.get("state", "")) == "insufficient":
		out["state"] = "insufficient"
		return out

	var has_budget := budget_p95 > 0.0 or budget_max > 0.0
	var pass_budget := true
	if budget_p95 > 0.0:
		pass_budget = pass_budget and p95 <= budget_p95
	if budget_max > 0.0:
		pass_budget = pass_budget and mx <= budget_max

	var drift := 0.0
	if not baseline.is_empty():
		var base_p95 := float(baseline.get("p95", 0.0))
		if base_p95 > 0.0:
			drift = (p95 - base_p95) / base_p95
	out["drift"] = snappedf(drift, 0.001)

	if not has_budget:
		# 没声明预算：只做「相对基线」的漂移判定，并明确说明这是相对口径
		if baseline.is_empty():
			out["state"] = "no_budget"
			out["notes"].append("未声明预算、也没有基线：这次运行只作为候选基线")
		else:
			out["state"] = "pass" if drift <= DRIFT_PASS else ("warn" if drift <= DRIFT_WARN else "fail")
			out["notes"].append("未声明预算，判定基于相对基线的漂移（Δ%+.1f%%）" % (drift * 100.0))
		return out

	if not pass_budget:
		out["state"] = "fail"
		var why := PackedStringArray()
		if budget_p95 > 0.0 and p95 > budget_p95:
			why.append("p95 %.2f > 预算 %.2f" % [p95, budget_p95])
		if budget_max > 0.0 and mx > budget_max:
			why.append("max %.2f > 预算 %.2f" % [mx, budget_max])
		out["notes"].append("超出预算：" + "；".join(why))
	elif drift > DRIFT_WARN:
		out["state"] = "fail"
		out["notes"].append("预算内，但相对基线漂移 %.1f%%（> %.0f%%）" % [drift * 100.0, DRIFT_WARN * 100.0])
	elif drift > DRIFT_PASS:
		out["state"] = "warn"
		out["notes"].append("预算内，相对基线漂移 %.1f%%（> %.0f%%）" % [drift * 100.0, DRIFT_PASS * 100.0])
	else:
		out["state"] = "pass"
	return out


static func baseline_path(scene: String) -> String:
	var key := scene if scene != "" else "unknown_scene"
	key = key.replace("res://", "").replace("user://", "")
	key = key.replace("/", "__").replace("\\", "__").replace(":", "_")
	return BASELINE_DIR.path_join(key + ".json")


static func save_baseline(summary: Dictionary, scene := "") -> Dictionary:
	var target_scene := scene if scene != "" else String(summary.get("scene", ""))
	var path := baseline_path(target_scene)
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return {"error": "无法创建基线目录 %s（err %d）" % [dir, mk]}
	var payload := {
		"schema_version": BBSchema.SCHEMA_VERSION,
		"scene": target_scene,
		"p50": summary.get("p50", 0.0),
		"p95": summary.get("p95", 0.0),
		"p99": summary.get("p99", 0.0),
		"max": summary.get("max", 0.0),
		"frames_used": summary.get("frames_used", 0),
		"created_unix": int(Time.get_unix_time_from_system()),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"error": "无法写入基线 %s" % path}
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return {"schema_version": BBSchema.SCHEMA_VERSION, "path": path, "baseline": payload}


static func load_baseline(scene: String) -> Dictionary:
	var path := baseline_path(scene)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


static func list_baselines() -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(BASELINE_DIR):
		return out
	for n in DirAccess.get_files_at(BASELINE_DIR):
		if n.get_extension().to_lower() == "json":
			out.append(BASELINE_DIR.path_join(n))
	out.sort()
	return out


## 读预算表（与 BB.set_budget 写的是同一个文件，格式 {"<拼键>": {"p95":..,"max":..}}）。
## CLI 没有 Autoload 时靠这个拿预算。
static func load_budget(scene: String, budget_file := "user://perf_blackbox/budgets.json") -> Dictionary:
	var budgets: Dictionary = {}
	if FileAccess.file_exists(budget_file):
		var f := FileAccess.open(budget_file, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				budgets = parsed
	if scene != "" and budgets.has(scene):
		return budgets[scene]
	if budgets.has("<default>"):
		return budgets["<default>"]
	var fallback := BBSettings.budget_default_p95()
	return {"p95": fallback, "max": 0.0, "default": true} if fallback > 0.0 else {}


static func _scene_of(pack: Dictionary) -> String:
	var snap: Dictionary = pack.get("scene_snapshot", {})
	var scene := String(snap.get("scene_path", ""))
	if scene == "":
		scene = String(pack.get("manifest", {}).get("scene", ""))
	return scene

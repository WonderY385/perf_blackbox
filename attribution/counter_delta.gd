@tool
class_name BBCounterDelta
extends RefCounted
## B3 引擎计数差分：每个事件附一张「计数器增量表」，全部带基线对比、z 值与首次变化帧。
## 累计型（pipeline）已在采样时就做了一阶差分；显存类按阶梯函数处理（取窗口内最大跳变）。


static func compute(ring: BBRingBuffer, base_from: int, base_to: int, win_from: int, win_to: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for col_name in BBScriptDelta.COUNTER_COLUMNS:
		var ci := BBSchema.column_index(col_name)
		if ci < 0:
			continue
		var base_series := _clean(ring.window(ci, base_from, base_to - base_from + 1))
		if base_series.size() < 3:
			continue
		var win_series := _clean(ring.window(ci, win_from, win_to - win_from + 1))
		if win_series.is_empty():
			continue

		var base_med := BBStats.median(base_series)
		var sigma := BBStats.robust_sigma(base_series, base_med)
		var floor := BBStats.noise_floor(base_med, 0.05, _abs_floor(col_name))
		var peak := BBStats.max_value(win_series)
		var delta := peak - base_med
		if absf(delta) <= floor:
			continue
		var z := BBStats.z_score(delta, sigma, floor)
		if z < 2.0:
			continue

		out.append({
			"key": col_name,
			"baseline": snappedf(base_med, 0.01),
			"peak": snappedf(peak, 0.01),
			"delta": snappedf(delta, 0.01),
			"z": snappedf(z, 0.01),
			"first_change_frame": _first_change(ring, ci, win_from, win_to, base_med, floor),
			"source": BBScriptDelta.COUNTER_SOURCE.get(col_name, ""),
		})

	out.sort_custom(func(a, b): return float(a["z"]) > float(b["z"]))
	return out


static func _clean(series: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for v in series:
		if v >= 0.0 and not is_nan(v):
			out.append(v)
	return out


static func _abs_floor(col_name: String) -> float:
	if col_name.ends_with("_ms"):
		return 0.05
	if col_name.ends_with("_kb"):
		return 64.0
	return 0.5


static func _first_change(ring: BBRingBuffer, ci: int, win_from: int, win_to: int, base: float, floor: float) -> int:
	for f in range(win_from, win_to + 1):
		var v := ring.value(ci, f)
		if v >= 0.0 and absf(v - base) > floor:
			return f
	return -1

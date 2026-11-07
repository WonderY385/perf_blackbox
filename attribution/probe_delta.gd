@tool
class_name BBProbeDelta
extends RefCounted
## B1 差分数学：相对基线窗口，哪些被插桩的函数「新出现」或「突增」。
## 只认「激活」语义：基线里一直跑的函数即使慢也大幅降权（那是背景，不是元凶）。

const Z_ACTIVATION := 3.0
const TOP_PER_SOURCE := 12


static func compute(base_from: int, base_to: int, win_from: int, win_to: int) -> Array[Dictionary]:
	var n_ids := BBProbe.id_count()
	if n_ids == 0:
		return []
	var base_frames := maxi(base_to - base_from + 1, 1)
	var win_frames := maxi(win_to - win_from + 1, 1)

	var base_calls := {}      # id -> int
	var win_calls := {}       # id -> int
	var win_first := {}       # id -> abs frame
	var win_self_us := {}     # id -> int
	var base_series := {}     # id -> PackedFloat64Array

	for f in range(base_from, base_to + 1):
		var e := BBProbe.frame_data(f)
		if e.is_empty():
			continue
		var c: Dictionary = e["c"]
		for id in c:
			base_calls[id] = int(base_calls.get(id, 0)) + int(c[id])

	for f in range(win_from, win_to + 1):
		var e := BBProbe.frame_data(f)
		if e.is_empty():
			continue
		var c: Dictionary = e["c"]
		for id in c:
			var calls := int(c[id])
			win_calls[id] = int(win_calls.get(id, 0)) + calls
			if not win_first.has(id):
				win_first[id] = f
		var u: Dictionary = e["u"]
		for id in u:
			win_self_us[id] = int(win_self_us.get(id, 0)) + int(u[id])

	# 逐帧序列用于 MAD（只在窗口内出现过的 id 才算，省时间）
	for id in win_calls:
		var series := PackedFloat64Array()
		for f in range(base_from, base_to + 1):
			var e := BBProbe.frame_data(f)
			if e.is_empty():
				series.append(0.0)
				continue
			var c: Dictionary = e["c"]
			series.append(float(c.get(id, 0)))
		base_series[id] = series

	var out: Array[Dictionary] = []
	for id in win_calls:
		var wc := int(win_calls[id])
		var bc := int(base_calls.get(id, 0))
		var base_rate := float(bc) / float(base_frames)
		var win_rate := float(wc) / float(win_frames)
		var delta := (win_rate - base_rate) * float(win_frames)
		var series: PackedFloat64Array = base_series.get(id, PackedFloat64Array())
		var sigma := BBStats.robust_sigma(series) if series.size() >= 3 else 0.0
		var floor := maxf(base_rate * 0.1, 0.5)
		var z := BBStats.z_score(win_rate - base_rate, sigma / float(base_frames), floor / float(base_frames))
		var activated := (bc == 0 and wc > 0) or z >= Z_ACTIVATION
		if not activated:
			continue
		out.append({
			"id": BBProbe.id_name(id),
			"calls": wc,
			"baseline_calls": bc,
			"first_seen_frame": int(win_first.get(id, -1)),
			"self_us": int(win_self_us.get(id, 0)),
			"delta": snappedf(delta, 0.1),
			"z": snappedf(z, 0.01),
			"in_baseline": bc > 0,
		})

	out.sort_custom(func(a, b): return float(a["z"]) > float(b["z"]))
	if out.size() > TOP_PER_SOURCE:
		out.resize(TOP_PER_SOURCE)
	return out

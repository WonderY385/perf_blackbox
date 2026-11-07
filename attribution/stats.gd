@tool
class_name BBStats
extends RefCounted
## 鲁棒统计：全部用中位数/MAD，不用均值/标准差（尖峰数据里均值无意义）。

const MAD_TO_SIGMA := 1.4826


static func median(values: PackedFloat64Array) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	var copy := values.duplicate()
	copy.sort()
	var mid := n >> 1
	if n % 2 == 1:
		return copy[mid]
	return (copy[mid - 1] + copy[mid]) * 0.5


static func mad(values: PackedFloat64Array, med: float = NAN) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	var m := median(values) if is_nan(med) else med
	var dev := PackedFloat64Array()
	dev.resize(n)
	for i in n:
		dev[i] = absf(values[i] - m)
	return median(dev)


static func robust_sigma(values: PackedFloat64Array, med: float = NAN) -> float:
	return mad(values, med) * MAD_TO_SIGMA


static func mean(values: PackedFloat64Array) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	var s := 0.0
	for i in n:
		s += values[i]
	return s / float(n)


## p ∈ [0,1]，线性插值分位数
static func percentile(values: PackedFloat64Array, p: float) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	var copy := values.duplicate()
	copy.sort()
	var pos := clampf(p, 0.0, 1.0) * float(n - 1)
	var lo := int(floor(pos))
	var hi := mini(lo + 1, n - 1)
	var frac := pos - float(lo)
	return lerpf(copy[lo], copy[hi], frac)


static func max_value(values: PackedFloat64Array) -> float:
	var n := values.size()
	if n == 0:
		return 0.0
	var m := values[0]
	for i in n:
		if values[i] > m:
			m = values[i]
	return m


## 鲁棒 z：delta / max(sigma, 噪声底)
static func z_score(delta: float, sigma: float, noise: float) -> float:
	var denom := maxf(sigma, noise)
	if denom <= 0.0:
		return 0.0 if is_zero_approx(delta) else 99.0
	return delta / denom


## 相对噪声底：max(ratio * |baseline|, abs_floor)
static func noise_floor(baseline: float, ratio := 0.05, abs_floor := 0.001) -> float:
	return maxf(absf(baseline) * ratio, abs_floor)


## 0..1 归一化（截断），用于打分前把不同尺度的量拉平
static func normalize(value: float, min_v: float, max_v: float) -> float:
	if max_v <= min_v:
		return 0.0
	return clampf((value - min_v) / (max_v - min_v), 0.0, 1.0)


## 均值的 bootstrap 置信区间（百分位法）。
## 用途：A/B 交错重测里，配对差分 d_i 的 95%CI —— 比「两组均值相减」稳得多。
## 返回 Vector2(ci_low, ci_high)；样本 < 2 时退化为 (mean, mean)。
static func mean_ci(values: PackedFloat64Array, iters := 1000, confidence := 0.95, rng_seed := 12345) -> Vector2:
	var n := values.size()
	if n == 0:
		return Vector2.ZERO
	var m := mean(values)
	if n < 2:
		return Vector2(m, m)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var means := PackedFloat64Array()
	means.resize(iters)
	for it in iters:
		var acc := 0.0
		for _i in n:
			acc += values[rng.randi_range(0, n - 1)]
		means[it] = acc / float(n)
	var alpha := (1.0 - confidence) * 0.5
	return Vector2(percentile(means, alpha), percentile(means, 1.0 - alpha))


## 样本标准差（n-1）；用于「最小可检测效应」的粗估
static func stdev(values: PackedFloat64Array) -> float:
	var n := values.size()
	if n < 2:
		return 0.0
	var m := mean(values)
	var acc := 0.0
	for v in values:
		acc += (v - m) * (v - m)
	return sqrt(acc / float(n - 1))

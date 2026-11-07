@tool
class_name BBRingBuffer
extends RefCounted
## A1 的存储层：列式环形缓冲（AoS→SoA）。
## - 容量取 2 的幂，用掩码取模；
## - 每列一个 PackedFloat64Array，写入零对象分配；
## - 绝对帧号单调递增（total 为下一次写入的帧号上界）。

var columns: PackedStringArray
var capacity: int
var mask: int
## 已写入的帧总数（= 最新帧号 + 1）
var total: int = 0

var _data: Array[PackedFloat64Array] = []


func _init(cols: PackedStringArray, cap: int) -> void:
	columns = cols
	capacity = _next_pow2(maxi(cap, 2))
	mask = capacity - 1
	for _i in columns.size():
		var col := PackedFloat64Array()
		col.resize(capacity)
		col.fill(0.0)
		_data.append(col)


static func _next_pow2(v: int) -> int:
	var p := 1
	while p < v:
		p <<= 1
	return p


func column_count() -> int:
	return _data.size()


## values 按 COLUMNS 顺序排列；越界部分补 0
func write_row(abs_frame: int, values: PackedFloat64Array) -> void:
	var slot := abs_frame & mask
	var n := _data.size()
	for c in n:
		_data[c][slot] = values[c] if c < values.size() else 0.0
	if abs_frame + 1 > total:
		total = abs_frame + 1


func value(col: int, abs_frame: int) -> float:
	if col < 0 or col >= _data.size():
		return BBSchema.UNAVAILABLE
	if abs_frame < oldest_abs() or abs_frame >= total:
		return BBSchema.UNAVAILABLE
	return _data[col][abs_frame & mask]


func column(col: int) -> PackedFloat64Array:
	return _data[col]


func oldest_abs() -> int:
	return maxi(0, total - capacity)


func clamp_from(from_abs: int) -> int:
	return maxi(oldest_abs(), from_abs)


## 取 [from_abs, from_abs+count) 的连续拷贝，越界自动裁剪
func window(col: int, from_abs: int, count: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	if col < 0 or col >= _data.size() or count <= 0:
		return out
	var first := maxi(oldest_abs(), from_abs)
	var last := mini(total, from_abs + count)
	var n := last - first
	if n <= 0:
		return out
	out.resize(n)
	var src := _data[col]
	for i in n:
		out[i] = src[(first + i) & mask]
	return out


## 把整段有效区导出成字典 {列名: PackedFloat64Array}（用于 .bhx）
func snapshot() -> Dictionary:
	var out := {}
	var first := oldest_abs()
	var n := total - first
	for c in _data.size():
		out[columns[c]] = window(c, first, n)
	return out

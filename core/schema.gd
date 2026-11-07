@tool
class_name BBSchema
extends RefCounted
## Perf Blackbox 全局常量与 .bhx schema 定义。
## 原则：任何「不可用」都写 -1.0（UNAVAILABLE），绝不写 0——0 是真实测量值。

const SCHEMA_VERSION := 1
const API_VERSION := 1
const TOOL_NAME := "perf_blackbox"
const TOOL_VERSION := "0.4.0"

## 采集产物目录（BB.DEFAULT_DIR 必须与此保持一致）
const CAPTURE_DIR := "user://perf_blackbox/captures"

## 列顺序 = frames.bin 的列顺序，改动必须升 SCHEMA_VERSION。
const COLUMNS: Array[String] = [
	"t_us",
	"frame_ms",
	"process_ms",
	"physics_ms",
	"render_cpu_ms",
	"render_gpu_ms",
	"draw_calls",
	"objects",
	"primitives",
	"video_mem_kb",
	"texture_mem_kb",
	"buffer_mem_kb",
	"pipeline_delta",
	"node_count",
	"object_count",
	"resource_count",
	"phys_active",
	"phys_pairs",
	"probe_calls",
	"overhead_us",
]

const COL := {
	"t_us": 0,
	"frame_ms": 1,
	"process_ms": 2,
	"physics_ms": 3,
	"render_cpu_ms": 4,
	"render_gpu_ms": 5,
	"draw_calls": 6,
	"objects": 7,
	"primitives": 8,
	"video_mem_kb": 9,
	"texture_mem_kb": 10,
	"buffer_mem_kb": 11,
	"pipeline_delta": 12,
	"node_count": 13,
	"object_count": 14,
	"resource_count": 15,
	"phys_active": 16,
	"phys_pairs": 17,
	"probe_calls": 18,
	"overhead_us": 19,
}

## 事件分级阈值（相对基线倍数）
const SEVERITY_MICRO := "micro"
const SEVERITY_HITCH := "hitch"
const SEVERITY_STALL := "stall"

const UNAVAILABLE := -1.0

## 本版本无法提供的数据源（写进 manifest.diagnostics，供读者解释缺口）
const UNAVAILABLE_SOURCES := {
	"script_profiler": "addon 侧拿不到引擎逐函数采样（ScriptLanguage::profiling_* 无 GDScript 绑定）→ B1 走探针",
	"process_physics_ms": "EngineDebugger.is_active() 在导出包为 false → process_ms/physics_ms 恒 -1",
	"resource_load_events": "ResourceLoader 无 signal → 资源加载只能由显存/管线跳变间接推断",
}

static func column_count() -> int:
	return COLUMNS.size()

static func column_index(name: String) -> int:
	return int(COL.get(name, -1))

## ratio = peak / baseline
static func severity_for(ratio: float, peak_ms: float) -> String:
	if ratio >= 5.0 or peak_ms > 100.0:
		return SEVERITY_STALL
	if ratio >= 2.5:
		return SEVERITY_HITCH
	return SEVERITY_MICRO

## JSON 友好：-1 转 null，NaN/INF 转 null
static func json_number(v: float) -> Variant:
	if is_nan(v) or is_inf(v) or is_equal_approx(v, UNAVAILABLE):
		return null
	return v

## 把 {"a": 1, "b": "x"} 里值为 -1 的数字清成 null（写出 JSON 前用）
static func sanitize(data: Variant) -> Variant:
	if data is Dictionary:
		var out := {}
		for k in data:
			out[k] = sanitize(data[k])
		return out
	if data is Array:
		var arr := []
		for v in data:
			arr.append(sanitize(v))
		return arr
	if typeof(data) == TYPE_FLOAT:
		return json_number(data)
	return data

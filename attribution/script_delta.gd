@tool
class_name BBScriptDelta
extends RefCounted
## B1 差分数学：相对基线窗口，哪些函数「新出现」或「突增」。
## 核心口径：base_rate = baseline_calls / baseline_frames，delta = (win_rate - base_rate) * win_frames
## 判定激活：(base_rate == 0 and win_rate > 0) 或 z >= 3

const Z_ACTIVATION := 3.0

## 可选计数器列（counter_delta 用）
const COUNTER_COLUMNS := [
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
	"render_cpu_ms",
	"render_gpu_ms",
]

const COUNTER_SOURCE := {
	"draw_calls": "Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME",
	"objects": "Performance.RENDER_TOTAL_OBJECTS_IN_FRAME",
	"primitives": "Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME",
	"video_mem_kb": "Performance.RENDER_VIDEO_MEM_USED",
	"texture_mem_kb": "Performance.RENDER_TEXTURE_MEM_USED",
	"buffer_mem_kb": "Performance.RENDER_BUFFER_MEM_USED",
	"pipeline_delta": "Performance.PIPELINE_COMPILATIONS_* 的一阶差分",
	"node_count": "Performance.OBJECT_NODE_COUNT",
	"object_count": "Performance.OBJECT_COUNT",
	"resource_count": "Performance.OBJECT_RESOURCE_COUNT",
	"phys_active": "Performance.PHYSICS_3D_ACTIVE_OBJECTS",
	"phys_pairs": "Performance.PHYSICS_3D_COLLISION_PAIRS",
	"render_cpu_ms": "RenderingServer.viewport_get_measured_render_time_cpu",
	"render_gpu_ms": "RenderingServer.viewport_get_measured_render_time_gpu",
}

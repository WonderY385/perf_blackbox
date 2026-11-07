# Perf Blackbox（性能黑匣子）v0.4.0

**警告⚠：此项目使用了AI代码。如果您不信任AI代码，请使用本插件经过人工审核的正式版本！**


面向 Godot 4 的 3D 项目开发者，不要求懂引擎内部。纯 GDScript，不用编译引擎。开发与验证环境：**Godot 4.7 / Forward+ / D3D12 / Jolt**。
当前版本 **0.4.0**，`.bhx` schema **v1**。


| 文档                           | 给谁看                                  |
| ---------------------------- | ------------------------------------ |
| **README.md**（本文）            | 想装上就用的人：怎么抓、怎么看、怎么把结果交给 AI           |
| [TECHNICAL.md](TECHNICAL.md) | 想改它 / 想信它的人：架构、算法、参数、引擎 API 事实与坑     |
| [PROTOCOL.md](PROTOCOL.md)   | 要接它的人：`.bhx` 格式、字段定义、CLI 与 MCP 的接口契约 |
| [LICENSE](LICENSE)           | CC0                                  |

## 目录
- [当前状态总览](#当前状态总览)
- [它解决什么问题](#它解决什么问题)
- [它不是什么](#它不是什么)
- [三分钟上手](#三分钟上手)
- [怎么看结果](#怎么看结果)
- [API 用法](#api-用法)
- [无头 CLI 与 CI 门禁](#无头-cli-与-ci-门禁f3040-新增)
- [MCP 服务](#mcp-服务f2040-新增)
- [提示词包怎么用](#提示词包怎么用)
- [五个最常见的坑](#五个最常见的坑)
- [常见 3D 优化示例](#常见-3d-优化示例)
- [自检](#自检)
- [路线图](#路线图)
- [许可](#许可)

## 它解决什么问题

- **美术换了一套材质，帧数掉了，你想知道是不是这套材质干的。** 事件窗口里纹理显存、管线编译、绘制调用和脚本调用会一起被摆出来，你能看到「换材质那一刻哪些信号真的变了」，而不是靠猜。
- **新加的敌人一进场就卡，但平时都好好的。** 插件会记录事件前后各 2 秒，把「新出现的节点类/场景/函数」单独列出来；基线里一直存在的东西会被排除，不会把常驻逻辑误判成元凶。
- **偶发卡顿抓不到、复现不了。** 常驻一个约 30 秒的环形缓冲，卡顿发生后 30 秒内就能把现场导出成 `.bhx`，事后慢慢看，不用一直盯着曲线。
- **想优化，但不知道先动哪。** 每个事件给出按可信度排序的候选（脚本/实体/计数三类证据），并明确写出「证据不足」的情况，避免你照着错误结论白改一通。
- **想请外部 AI 帮忙，又不想把整个项目贴出去。** 一键生成约 2000 token 的提示词包，只含环境、事件、候选、时间线和硬约束；不需要联网、不需要装 MCP 客户端。

## 它不是什么

- **不是 profiler 内核，也不出火焰图。** 引擎已经有 Profiler；而且纯 GDScript 插件拿不到函数级采样（数据是单向发往编辑器的，没有脚本绑定）。重复造这个轮子既贵又不准。
- **不是优化规则库/优化顾问。** 它不内置「你应该开 occlusion culling」这类通用建议。结论必须由你项目这一次的数据支撑；需要外部推理时，把证据交给 AI，而不是让插件假装什么都懂。
- **不是录屏/性能视频工具。** GDScript 扩展不了 MovieWriter，做视频要 C++。它用「事件包 + 逐帧数据 + 可交互时间线」替代视频，体积小、可搜索、可 diff。
- **不是云服务，也不做遥测。** 不联网、不上传。包就在本机 `user://perf_blackbox/captures/`，拷走、删掉都由你。
- **不是通用场景导出器。** 场景快照只记「事件窗口里新出现了哪些场景路径/节点类」，不做完整场景树导出。

这样设计的理由很直接：性能工具的价值在「证据是否可信、是否对得上你刚才看到的那一帧」，而不在功能列表有多长。少做一点，做准一点。

## 三分钟上手

### 第 1 步：装进项目（约 1 分钟）

1. 把 `addons/perf_blackbox/` 整个目录拷到你的项目 `addons/` 下。
2. 打开 **项目 → 项目设置 → 自动加载**，确认有一项：名称 `BB`，路径 `res://addons/perf_blackbox/core/bb.gd`。本仓库已经配好；如果你是把插件拷到新项目，需要手动加这一项（启用插件本身不会自动创建 Autoload）。
3. 打开 **项目 → 项目设置 → 插件**，勾选 **Perf Blackbox**。编辑器底部会出现标签为 `PBb` 的面板。
4. 测试期间建议先关掉 V-Sync、把 `Engine.max_fps` 设为 0（原因见[TECHNICAL.md](TECHNICAL.md#引擎-api-事实与坑)）；发布设置不用动。

### 第 2 步：跑起来，让它抓下一次卡顿

先正常进入游戏，再复现你想查的那次卡顿（换材质、进战斗、开一扇门……）。在游戏里挂一个临时脚本（测完删掉），或者直接在现有脚本里加这几行：

```gdscript
func _ready() -> void:
	BB.capture_finished.connect(func(pack: Dictionary) -> void:
		print("[Perf Blackbox] 已导出：", BB.export_pack(pack).get("path", ""))
	)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F8:
		BB.capture_next_hitch(20.0)   # 进入游戏后再按 F8，避开开场加载
```

`capture_next_hitch()` 不会阻塞游戏：需要时它会自动开始采集，检测到第一个掉帧事件（或 20 秒超时）就停止，并发出 `capture_finished(pack)`。**一定要在这个信号里导出**，否则退出游戏后包就没了。

几个要点：

- 检测器需要约 2 秒（120 帧）预热。开场加载的卡顿往往发生在这之前，所以先进入游戏、再复现。
- 想自己控制起止：`BB.start_capture()` 在内存里滚动记录最近约 30 秒，卡顿后 `BB.stop_capture()` 取包；`BB.mark("boss 二阶段")` 给事件窗口打书签；导出不写路径时默认落到 `user://perf_blackbox/captures/`。
- 抓不到也别硬等：20 秒内没有事件也会停，报告会说明「这是一份基线包」，可以拿它当对照。

### 第 3 步：在 `PBb` 面板里看报告

回到编辑器，打开底部 `PBb`：

1. 左侧列表会自动出现最新的 `.bhx`（勾选「自动」时每秒扫描一次）。
2. 点 `事件` tab，看这一包里有几次掉帧、峰值多少 ms、是基线的几倍、归因是什么。
3. 点 `报告` tab，从上往下读：TL;DR → 事件表 → 每个事件的窗口/候选/排除项 → 复现步骤 → 环境 → 数据完整性诊断。
4. 点 `诊断` tab，先确认三件事：`vsync` 是不是 false、你的关键列有没有被标成不可用、插件自身开销有没有超 0.5 ms。

如果这一包没有事件，报告会明确说「这是一份基线包」——这也有用，后面可以拿它当对照。

### 第 4 步：把提示词丢给 AI

在面板点「导出提示词」，会在 `.bhx` 旁边生成 `<包名>.prompt.md`。把整个文件复制到任意 AI（ChatGPT、Claude、DeepSeek 都行），它已经写好了角色、硬约束和期望的 JSON 格式，不需要你再解释背景。

拿到回答后，先别急着改代码：检查它引用的证据编号（如 `[evt_0001/e1]`）是否真的存在于你的包里。查不到，就当它在编。

## 怎么看结果

打开底部 `PBb` 面板，选一个包，六个 tab 各管一件事。字段的精确含义（每一列、每个事件键、每条证据）在 [PROTOCOL.md](PROTOCOL.md)；这里只说「该看哪个」。

### 面板六个 tab

| tab | 你能看到什么 | 什么时候用 |
| --- | --- | --- |
| 事件 | 7 列表格：id、峰值帧、峰值 ms、基线 ms、倍数、分级、归因 | 先扫一眼这包值不值得细看 |
| 时间线 | 可悬停/点击的帧曲线：粗线=每桶最大值，细线=中位数，事件窗口有底色，悬停显示该帧数值 | 想知道「卡顿前后到底长什么样」「是不是周期性的」 |
| 原因 | 选中事件的纯文本摘要：窗口、候选、排除项、说明 | 快速判断「有没有锁定原因」 |
| 报告 | 完整中文报告（同 `report.md`） | 贴给同事、存档、按复现步骤重跑 |
| 提示词 | 约 2000 token 的提示词全文（同 `prompt.md`） | 复制到外部 AI |
| 诊断 | 文件、schema、帧数、列数、探针 id/帧数、不可用列、结构性缺口、降级、自身开销、引擎、settings_hash、vsync，以及 **D1 预算与基线**（状态/p50/p95/p99/max/基线路径） | **每次采集后先看这里**，确认数据可信 |

面板只读 `.bhx`，不会改你的包；「导出报告」「导出提示词」「导出 HTML 时间线」会在包旁边写 `<包名>.report.md`、`<包名>.prompt.md`、`<包名>.timeline.html`。HTML 是自包含单文件（数据内嵌，不联网、不引 CDN），可以直接发给别人用浏览器打开。

## API 用法

所有调用都在运行中的游戏里（编辑器内 `BB` 不采集）。以下签名与当前实现一致。

### 采集控制

| 调用 | 作用 | 返回/备注 |
| --- | --- | --- |
| `BB.start_capture(opts := {})` | 开始常驻采集 | `{ok, started_frame, ring, probe, schema_version}`；`opts.ring` 默认 1800，`opts.probe` 为 `"count"`/`"time"`/`"off"` |
| `BB.stop_capture()` | 停止并返回内存包 | 包字典；**不写盘**，写盘用 `export_pack` |
| `BB.capture_next_hitch(timeout_s := 30.0)` | 武装一次性录制 | 立刻返回 `{ok, timeout_s, events_before}`；检测到事件或超时自动停 |
| `BB.is_capturing()` | 是否正在采集 | `bool` |
| `BB.is_waiting_for_hitch()` | 是否在等下一次掉帧 | `bool` |
| `BB.capture_dir()` | 默认采集目录 | `user://perf_blackbox/captures` |
| `BB.mark(label)` | 给当前时刻打书签 | `bool`；没在采集时返回 `false` |

```gdscript
# 常驻采集，手动停止
BB.start_capture({"ring": 1800, "probe": "count"})
# ... 复现卡顿 ...
var pack := BB.stop_capture()
var r := BB.export_pack(pack)          # 自动存到 user://perf_blackbox/captures/
print(r.path, " / ", r.bytes, " bytes / ", r.event_count, " events")
```

### 读取事件

| 调用 | 作用 | 返回 |
| --- | --- | --- |
| `BB.events()` | 当前采集或上一包的事件摘要 | `Array[Dictionary]`，含 id/峰值/倍数/归因等 |
| `BB.get_event(id)` | 单个事件详情 | 事件字典 + `delta`（三类证据、排序、排除项） |
| `BB.last_pack()` | 最近一次停止得到的包 | 内存字典；没有则空 |
| `BB.last_pack_info()` | 包的概要 | 帧数、起始帧、事件数、耗时、降级 |

```gdscript
for ev in BB.events():
	print("%s  %.1fms  基线 %.1fms  %.1fx  %s" % [
		ev.id, ev.peak_ms, ev.baseline_ms, ev.ratio, ev.severity
	])

var detail := BB.get_event("evt_0001")
print(detail.delta.get("root_cause", "inconclusive"))
print(detail.delta.get("ranking", []))
```

### 导出与对比

| 调用 | 作用 | 返回/备注 |
| --- | --- | --- |
| `BB.export_pack(pack := {}, path := "", format := "bhx")` | 导出包/报告/提示词/JSON | `format` 为 `"bhx"`/`"md"`/`"prompt"`/`"json"`；空 `path` 自动命名；空 `pack` 用 `last_pack` |
| `BB.export_last(format := "bhx")` | 导出最近一包 | 同上；没有包时返回 `{ok:false, error:"no_pack"}` |
| `BB.compare(baseline, current)` | 两段采集的帧时间对比 | `{delta_median_ms, delta_p95_ms, noise_floor_ms, verdict, columns}`；`verdict` 为 `slower`/`faster`/`unchanged` |

```gdscript
# 同一次运行里采两段：例如关掉某系统之前 / 之后
var a := BB.stop_capture()
# ... 切换系统、换场景、改配置 ...
BB.start_capture()
# ... 再跑同样的路线 ...
var b := BB.stop_capture()

var diff := BB.compare(a, b)
print(diff.verdict, "  p95 ", diff.delta_p95_ms, "ms（噪声底 ", diff.noise_floor_ms, "ms）")
```

`compare()` 的 `verdict` 只看 `frame_ms` 中位数的变化是否超过噪声底（基线中位数的 5%，下限 0.001 ms）；返回值里同时带 `delta_p95_ms` 和各列的中位数差值，供你参考。它**校验**不了环境是否一致，也**不**做事件配对——跨运行/跨提交比较请用 D3 的 `BB.regression(a, b)`（`verdict` / `exit_code` / 事件指纹配对都在那里）；只想快速看一眼两包帧时间差异时再用 `compare()`。

### 时间线（C3，0.3.0 新增）

| 调用 | 作用 | 返回/备注 |
| --- | --- | --- |
| `BB.export_timeline(pack := {}, path := "")` | 生成一份自包含 HTML 时间线 | 空 `pack` 用 `last_pack`；空 `path` 自动落到 `user://perf_blackbox/captures/`；HTML 内嵌数据，双击即可用浏览器打开，不联网 |

```gdscript
var r := BB.export_timeline(pack)   # 也可以传路径：BB.export_timeline(pack, "user://t.html")
print(r.path)
```

时间线把整包帧数据降采样成最多 600 个桶：粗线是每个桶的**最大** `frame_ms`，细线是**中位数**，另有一条 GPU 时间曲线；事件窗口用底色标出，悬停能看该帧数值。面板里的「时间线」tab 是同一份数据的可交互版本（悬停看数值，点击发出帧选择信号）。它不是视频，不占几十 MB，也不需要编码器。

### 预算与基线（D1，0.3.0 新增）

| 调用 | 作用 | 返回/备注 |
| --- | --- | --- |
| `BB.set_budget(scene, p95_ms, max_ms := 0.0)` | 给某张图声明帧预算 | `scene` 传 `""` 表示默认预算；写到 `user://perf_blackbox/budgets.json` |
| `BB.get_budget(scene := "")` | 读预算 | 没声明时回退默认预算或 `perf_blackbox/budget_default_p95` |
| `BB.evaluate_budget(pack := {})` | 评估一包是否达标 | `state` 为 `pass`/`warn`/`fail`/`insufficient`/`no_budget`；带 p50/p95/p99/max、漂移与说明 |
| `BB.get_budget_status()` | 最近一包的一行状态 | 面板诊断 tab 用的就是这类字段 |
| `BB.save_baseline(pack := {}, scene := "")` | 把这次统计存成基线 | 写到 `res://.perf_blackbox/baselines/*.json`，可随仓库提交 |

```gdscript
# 目标 60fps：p95 不超过 16.6ms，单帧极值不超过 33ms
BB.set_budget("res://levels/forest.tscn", 16.6, 33.0)

var pack := BB.stop_capture()
var b := BB.evaluate_budget(pack)
print(b.state, "  p95=", b.p95, "  drift=", b.drift)
BB.save_baseline(pack)     # 下次同场景采集会自动和它比
```

判定口径固定写在结果里：先剔除开头 2 秒预热，再用剩余帧算 p50/p95/p99；`max` 取 p99.9，避免单帧异常把结论带偏；有效帧少于 300 时只给 `insufficient`，不下结论。没声明预算时，若存在基线，就按相对漂移判定：3% 内 `pass`、10% 内 `warn`、超过 10% `fail`。注意默认 `budget_default_p95` 是 16.6 ms，所以即使你没调用 `set_budget()`，也会按 60fps 的默认预算判一次；不想要这个默认门禁，把 `perf_blackbox/budget_default_p95` 设为 `0`。面板诊断 tab 用的是默认预算，按场景的精细预算请以 `BB.evaluate_budget(pack)` 为准。

> 基线写入 `res://`，请在编辑器或 CI 里做；导出后的游戏通常不能写 `res://`。

### 系统成本账本（D2，0.3.0 新增）

| 调用 | 作用 | 返回/备注 |
| --- | --- | --- |
| `BB.define_system(spec)` | 注册一个可开关的「系统」 | `spec` 含 `name`、`kind`（`node`/`group`/`custom`）、`target` 或 `set_enabled` |
| `BB.list_systems()` | 列出已注册系统 | `[{name, kind}]` |
| `BB.measure_system(name, opts := {}, spec := {})` | 测这个系统值多少毫秒 | **必须 `await`**；默认 4 轮 A/B，每轮 3 秒预热 + 5 秒采样；结果另存 `user://perf_blackbox/ledger/<name>.json` |

```gdscript
# 注册：整个 "enemies" 分组算一个系统
BB.define_system({"name": "敌人AI", "kind": "group", "target": "enemies"})

# 测量：必须在 async 上下文里 await；一次默认约 1 分钟
func profile_enemies() -> void:
	var r: Dictionary = await BB.measure_system("敌人AI", {"runs": 4, "warmup_s": 3.0, "sample_s": 5.0})
	print("约 ", r.delta_ms, " ms  CI [", r.ci_low_ms, ", ", r.ci_high_ms, "]  significant=", r.significant)
```

它不靠「跑两次相减」，因为帧耗时的自然抖动经常比 1–2 ms 的效应还大。做法是 A/B/A/B 交错多轮：每轮取帧内**忙时间的中位数**（比墙钟帧间隔稳定，也不会被偶发尖刺带偏），算配对差分 `B−A`，再用 bootstrap 求 95% 置信区间；只有区间下界也高于噪声底（基线的 5% 与 0.1 ms 取大）才判 `significant`。`delta_ms` 量的是帧内忙时间，不是墙钟帧间隔——vsync 或 headless 的空闲睡眠不会把真实 CPU 成本吃掉。

三种开关：`node` 对目标节点递归切 `process_mode`/`visible`/物理；`group` 对整组做同样的事；`custom` 调用你给的 `set_enabled(bool)`（Autoload/插件/feature flag 用这个）。测量期间插件会先停掉自己的采集，测完恢复。GPU 拆分只在渲染计时可用时有值，headless 下为 `-1`；CPU 拆分目前也返回 `-1`（还没有接），主看 `delta_ms` 和 `frame_delta_ms`。

### 设置与隐私（F4，0.3.0 新增）

所有键都在 **项目设置** 里，前缀 `perf_blackbox/`，不改也能跑：

| 键 | 默认 | 作用 |
| --- | --- | --- |
| `enabled` | `true` | 总开关；关掉后 `start_capture()` 直接返回 `disabled_by_settings` |
| `ring_capacity` | `1800` | 环形缓冲帧数（约 30 秒 @60fps） |
| `probe_mode` | `count` | 探针模式：`off`/`count`/`time` |
| `max_overhead_ms` | `0.5` | 采集自身上限；超过自动降档 |
| `budget_default_p95` | `16.6` | 默认 p95 预算（毫秒） |
| `capture_shots` | `false` | 📋 预留：掉帧截图尚未真正落盘，当前不会产生图片（抓帧有延迟成本，要单独设计时机） |
| `mcp_enabled` | `false` | 预留开关：MCP 服务目前手动用 `--script tools/bb_mcp.gd` 起，不读这个开关 |
| `strip_paths` | `true` | 导出时把本机绝对路径压成 `<abs>/最后两段`，`res://` 写成 `<project>/...` |
| `hash_project_name` | `false` | 导出时把项目名替换成哈希 |
| `keep_captures` | `50` | captures 目录最多保留多少个包（按修改时间轮转） |

脱敏只在写 `.bhx` 的唯一入口做一次，避免「某个出口忘了脱敏」。插件不联网、不上传任何东西；`strip_paths` 默认开启，但项目内路径、GPU 型号、CPU 核心数和系统版本仍会留在包里，外发前自己再看一眼。

### 探针：`count` / `time` / `off` 怎么选

| 模式 | 成本 | 能回答什么 | 建议 |
| --- | --- | --- | --- |
| `"count"` | 几乎为零：一次 id 查找 + 一次整数自增 | 这个函数这一帧被调了多少次 | 默认；先大面积 `count` 缩小范围 |
| `"time"` | 约 0.4–0.8 µs/次，另加栈操作 | 这个函数自己花了多少微秒（已扣子调用） | 只对 2–3 个可疑函数开；支持嵌套 |
| `"off"` | 探针调用立即返回 | 不做函数级归因 | 只想量帧时间、或排查探针本身干扰时 |

```gdscript
# 计数：放在函数第一行
func _process(delta: float) -> void:
	BBProbe.count("Enemy::_process")
	# ... 原有逻辑 ...

# 计时：begin/end 必须配对；有提前 return 时要格外小心
func _physics_process(delta: float) -> void:
	var t := BBProbe.begin("World::_physics_process")
	# ... 原有逻辑 ...
	BBProbe.end("World::_physics_process", t)
```

计时模式要在开始采集时指定：`BB.start_capture({"probe": "time"})`。自身开销超过预算时，守卫会自动把 `time` 降回 `count`、甚至关掉探针；这时事件的 `confidence` 会下调，诊断 tab 里能看到降级记录。

### 信号

| 信号 | 何时发出 | 参数 |
| --- | --- | --- |
| `event_captured` | 每检测到一个事件 | `event: Dictionary` |
| `capture_finished` | 每次 `stop_capture` / 一次性录制结束 | `pack: Dictionary` |
| `degraded` | 开销守卫升档/降档 | `level: int`, `reasons: PackedStringArray` |
| `budget_exceeded` | 自身开销首次超预算，或停止时场景预算判定为 warn/fail | `status: Dictionary` |

注意：`budget_exceeded` 有两种触发来源：本次采集的**插件自身开销**首次超预算（默认 0.5 ms/帧），以及停止时 **D1 场景预算**判定为 warn/fail。两者不是一回事，先看 `status` 里的字段，或直接看诊断 tab 的自身开销。停止时得到的包还会带一个 `budget_status` 字段，就是这次 D1 判定的结果。

```gdscript
BB.event_captured.connect(func(ev: Dictionary) -> void:
	print("卡顿 %s：%.1fms（%.1fx，%s）" % [ev.id, ev.peak_ms, ev.ratio, ev.severity])
)
BB.degraded.connect(func(level: int, reasons: PackedStringArray) -> void:
	push_warning("采集降档 L%d：%s" % [level, ", ".join(reasons)])
)
```

### 静态清单（E1，0.4.0 新增）

不看运行，只看场景本身：多少网格、多少重复网格、多少灯开阴影、多少透明材质、多少物体没有可见距离。输出是 Markdown + 结构化字典，可以直接当提示词的「项目背景」。

```gdscript
# 运行时：当前场景
var manifest: Dictionary = BB.render_manifest()

# 指定节点
var m2: Dictionary = BB.render_manifest(get_node("World"))

# 直接给场景文件（不需要进游戏，编辑器里也能用）
var m3: Dictionary = BB.render_manifest("res://levels/forest.tscn")

# 落盘成 Markdown
BB.export_render_manifest("res://levels/forest.tscn", "res://perf_manifest_city.md")
print(m3.markdown)
print(m3.totals.mesh_instances, " 个网格实例，", m3.totals.shadow_casters, " 个投射阴影")
```

面板工具栏的「渲染清单」按钮就是调它，结果写进诊断 tab 并顺手导出 `.md`。

### 静态 × 实测关联（E2，0.4.0 新增）

把「掉帧那一刻新增了什么」和静态清单对上，产出**假设**和**验证步骤**，而不是直接下结论。

```gdscript
var manifest: Dictionary = BB.render_manifest("res://levels/forest.tscn")
var pack: Dictionary = BB.last_pack()
var rel: Dictionary = BB.correlate(pack, manifest)
for h in rel.hypotheses:
	print("%s | 置信 %.2f | %s" % [h.key, h.confidence, ", ".join(h.tags)])
	# h.experiment 就是可直接照做的开关步骤

var plan: Dictionary = BB.plan_experiment("node_class", "MeshInstance3D", 200)
print(plan.markdown)
```

置信度是**证据强度**，不是「一定有罪」：静态清单里同类很多、掉帧时 draw call 明显跳变、且这批实体是基线里没有的，才会往上走。`needs_more_data` 为真时说明证据不足，先补测再下判断。

### 跨运行回归（D3，0.4.0 新增）

两次运行/两个提交各采一包，直接比。`a`/`b` 既可以是包字典，也可以是 `.bhx` 路径。

```gdscript
var diff: Dictionary = BB.regression("user://perf_blackbox/captures/old.bhx", "user://perf_blackbox/captures/new.bhx")
print(diff.verdict, " exit=", diff.exit_code)   # regression / improvement / unchanged / not_comparable
print(diff.frame.delta_p95_ms, "ms  p95 变化；噪声底 ", diff.frame.noise_floor_ms)
BB.export_regression("old.bhx", "new.bhx", "res://regress.md")
```

两条纪律：

- **环境不一致就不下结论**。`settings_hash`、vsync、`max_fps`、headless 任一项不同，`compatible=false`，`verdict` 变成 `not_comparable`，只给绝对数值。
- **事件按指纹配对，不按 id**。id 每次重新编号（`evt_0001` 的含义会变），指纹是「分级 + 头号原因 + peak 比值」，这样才能说「这个老毛病这次更严重了」还是「冒出来一个新问题」。

对比一次性结束、退出码给 CI 用：`0` 无回归、`2` 有回归。CLI 里是 `--regress=`，见下一节。

### 接入向导与自动插桩（D4，0.4.0 新增）

新加一个系统或插件后，让它告诉你「该系统在场景里对应哪些节点、哪些函数值得插探针」。

```gdscript
var wiz: Dictionary = BB.wizard_for_scene("res://test.tscn")   # 传空则用当前场景
print(wiz.markdown)          # 候选系统（kind=node/group）+ 建议插桩的函数
# 面板工具栏的「接入向导」按钮 = 同样的东西

# 自动插桩（只插入口函数，失败自动回滚）
var r: Dictionary = BB.instrument_script("res://scripts/enemy.gd")
# r.inserted / r.skipped / r.backup_path
BB.revert_instrumentation("res://scripts/enemy.gd")   # 反悔
```

插桩的边界：只处理 GDScript，只插「入口级」函数（`_ready`/`_process`/`_physics_process`/`_input`/`_unhandled_input`/`_integrate_forces` 等），写入前备份 `.bak`，写完用 `GDScript.new()+reload()` 校验，失败就还原。**C# 脚本明确跳过**——插件没法给 C# 注入代码，别指望它。

## 无头 CLI 与 CI 门禁（F3，0.4.0 新增）

`addons/perf_blackbox/tools/bb_cli.gd` 是个 `SceneTree` 脚本，不需要编辑器窗口：

> 注意：**不要加 `--quiet`**。CLI 的结果是 `print` 到 stdout 的，而 `--quiet` 会把 `print()` 一起压掉（只剩引擎横幅和别人的插件日志）。`--quiet` 只在 MCP 服务那边用，因为 MCP 走 TCP、不靠 stdout。

```bash
# 列出本机所有采集包
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --list-packs

# 把某个包导成报告 / 提示词 / 时间线 HTML / 渲染清单
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --report="user://perf_blackbox/captures/x.bhx"
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --prompt="x.bhx" --tokens=1200
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --timeline="x.bhx"
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --manifest="res://levels/forest.tscn"

# CI 门禁：超预算或回归 → 退出码 2
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --budget-gate="x.bhx"
godot --headless --path "<项目>" --script res://addons/perf_blackbox/tools/bb_cli.gd -- --regress="old.bhx,new.bhx" --out="res://regress.md"
```

退出码约定：`0` 通过 · `2` 超预算或有回归 · `1` 用法错误。`--out`/`--tokens`/`--dir` 是全局修饰，可以跟在任何子命令后面。

> CI 里要注意：headless 没有真实渲染，`render_gpu_ms`、`draw_calls` 等会标成不可用（`-1`）而不是 0。所以 `--budget-gate` 在 CI 里只对 CPU/逻辑帧时间有意义，别指望它挡住 GPU 侧退化。

## MCP 服务（F2，0.4.0 新增）

给 Claude Code / Cursor 这类客户端提供 10 个只读工具：列包、事件表、事件详情、报告、提示词、时间线、渲染清单、回归、预算判定、静态关联。

**传输层是本机 TCP，不是 stdio**——原因很硬：Godot 启动会把版本横幅 `print` 到 stdout，而 `--quiet` 会把横幅和 `print()` 一起压掉，本项目还装了别的带 autoload 的插件（会往 stdout 打日志）。任何严格按行解析 JSON 的客户端都会被这些噪音搞崩。所以走 TCP，一行一条 JSON-RPC。

```bash
# 启动服务（默认 127.0.0.1:43790，可用 --port= 改）
godot --headless --quiet --path "<项目>" --script res://addons/perf_blackbox/tools/bb_mcp.gd -- --port=43790
```

然后随便找个「一行一条 JSON-RPC」的客户端/中继接上去，先发 `initialize`，再 `tools/list`：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"my-agent","version":"1"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"bb_budget_gate","arguments":{"pack":"user://perf_blackbox/captures/x.bhx"}}}
```

工具都是**瘦的只读查询**，不做分析（分析在包里已经做完了）。日志一律走 stderr，stderr 里的 `[bb_mcp] ...` 是启动/连接信息，不影响协议。

## 提示词包怎么用

### 它给 AI 什么

`prompt.md` 不是把整个项目丢出去，而是一份刻意压缩过的证据摘要：

- **角色与硬约束**：限定「Godot 4 渲染/性能工程师」，要求只基于证据下结论、每条结论引用 `evidence_id`、证据不足必须说 `needs_more_data`、区分事实与假设。
- **项目背景**：引擎版本、渲染器、驱动、物理后端、GPU、vsync、max_fps、是否 headless。
- **事件总表**：每个事件的峰值/基线/倍数/帧范围/分级/标签。
- **逐事件证据**：窗口与基线窗口、30 点抽稀时间线（`*` 标峰值帧）、top 候选（带 `[evt_0001/e1]` 形式的证据编号）、已排除项、说明。
- **数值摘要**：`frame_ms` 的 min/median/p95/max。

默认预算 2000 token；超了会自动降级到 L1（只留每事件 top-4 候选）或 L0（只留最严重事件）。文件末尾会注明压缩到了哪一级、估计多少 token。token 是保守估算（ASCII 按 4 字符/token，中文按 1.5 字符/token），不是精确值。

> 提示词包的完整骨架与「期望 AI 返回的 JSON 契约」在 [PROTOCOL.md](PROTOCOL.md#提示词包契约)。

## 五个最常见的坑

完整清单（15 条）在 [TECHNICAL.md](TECHNICAL.md#已知限制与设计权衡)，这里只挑最影响使用体验的：

1. **开 vsync 会把真实帧时间藏起来。** 帧时间被锁在 16.7 ms，有 5 ms 余量你也看不出来。测量时关 vsync、`Engine.max_fps = 0`。
2. **编辑器插件/调试器/MCP 会污染基线。** 采集时关掉其它桥接插件，至少保证基线和事件在同一条件下采。
3. **headless 下渲染列不可用（`-1`，不是 0）。** 无头 CI 只能门禁 CPU/逻辑指标，渲染要在有 GPU 的机器上测。
4. **`process_ms`/`physics_ms` 只在有调试器时有值。** 导出包和直接运行是 `-1`，别当 0 参与计算。
5. **启动后前约 2 秒不检测。** 开场加载的卡顿会漏掉；要抓加载，就在加载开始前先 `start_capture()`。

## 常见 3D 优化示例

下面每个例子都按「症状 → 用插件怎么确认 → 通常的处理方向 → 怎么验证有效」写。先记住通用流程：**关 vsync → 跑问题场景 → 复现 → 导出 → 看事件/报告/诊断 → 只改一个变量 → 用同样路线再采一包对比**。

跨代码版本的对比用 D3：`BB.regression("old.bhx", "new.bhx")`，它先比环境（`settings_hash` 等），再比 p50/p95/p99/max、配对事件，最后给 `verdict` 和退出码；环境不一致会直接判 `not_comparable`。`BB.compare()` 保留给「我就想快看一眼两个包帧时间差」的场合。

### 1. 大量重复物体：draw call 爆炸

- **症状**：场景里几百上千个相同/相似物体，`frame_ms` 长期偏高；`draw_calls` 很高，`render_cpu_ms` 也跟着高，但 GPU 可能还有余量。
- **用插件怎么确认**：采一段，打开事件 → 看 `draw_calls`、`objects`、`primitives` 在事件窗口里是否明显高于基线；报告里计数归因会给出「基线 → 峰值」；诊断 tab 确认 `draw_calls` 不是 `-1`。如果后端不支持这一列，就用 `objects`/`primitives` 和「临时隐藏一半物体再采」来对照。
- **通常的处理方向**：相同网格用 `MultiMeshInstance3D`；静态小物件合并网格；给装饰物设 `visibility_range`；用遮挡/视锥剔除减少同时可见数量；远景换 LOD；小物件关闭阴影投射。
- **怎么验证有效**：同一相机路线再采一包，看 `draw_calls` 的峰值和中位数是否下降、`frame_ms` 的 p95 是否下降、事件是否还出现。不要只看某一帧，至少跑 10 秒。

### 2. 阴影与实时灯光过多

- **症状**：夜景或室内场景，灯一多就掉帧；`render_gpu_ms` 高，关掉阴影立刻好转；`frame_ms` 尖峰常出现在镜头转向、更多灯进入视野时。
- **用插件怎么确认**：采一包，看事件窗口的 `render_gpu_ms` 峰值相对基线的变化（记住它是上一帧的值，看窗口趋势而不是单帧）；`tags` 里不一定有阴影标签，所以再做一次手动对照：关掉一组灯的 `shadow_enabled`，同路线再采一包，比较 GPU 时间。如果这些灯能整组开关，也可以注册成系统后用 `await BB.measure_system(...)` 直接量出毫秒数与置信区间（见 API 的 D2 一节）。
- **通常的处理方向**：减少投射阴影的灯（只让主光/关键光投影）；调小阴影距离和 atlas 分辨率；静态场景烘焙光照；装饰灯关阴影、降能量/距离；用 `Light3D` 的可见距离限制。
- **怎么验证有效**：两包的 `render_gpu_ms` 中位数/p95 对比；事件数量是否减少；画面是否能接受（别为了 2 ms 把主光阴影也关了）。

### 3. 透明材质 / overdraw：GPU fill-bound

- **症状**：看向树叶、玻璃、粒子、烟雾、UI 叠加层时帧时间明显变差；`draw_calls` 不一定高，`render_gpu_ms` 高；降低分辨率会明显变快。
- **用插件怎么确认**：先采一包有问题的视角；再把最可疑的半透明层隐藏（或把粒子数量减半），同视角再采一包。比较 `render_gpu_ms`。另一个判据：临时把 3D 缩放降到 0.5 再采一包，如果 GPU 时间大幅下降，基本就是填充率/overdraw 问题（两次采集要分开，不要边改边采）。
- **通常的处理方向**：减少重叠的半透明层数；能用 alpha scissor/不透明就用，别全程 alpha blend；缩小粒子尺寸和数量、减少过大的软粒子；避免全屏透明面片；检查后处理是否叠了多层全屏 pass。
- **怎么验证有效**：同视角、同分辨率的两包 `render_gpu_ms` 对比；`frame_ms` p95；事件是否消失。透明排序问题还可能表现为闪烁，别只盯帧数。

### 4. 首次加载卡顿 vs 运行中卡顿

- **症状**：第一次进入某个区域/打开某个界面会卡，第二次就顺了；或者运行中每隔一会儿卡一下。
- **用插件怎么确认**：看事件的 `tags`。`pipeline_compile` 表示窗口里管线编译数跳了；`scene_load` 表示窗口里有新的场景文件被实例化进来（节点类新增只会进实体证据，不一定会打这个标签）；`pipeline_delta`、`resource_count`、`node_count` 的跳变能互相印证。资源加载事件本身拿不到（`ResourceLoader` 没有 signal），所以只能靠这些间接证据。
- **通常的处理方向**：把材质/着色器预热放到加载界面（先让它们渲染一帧）；资源用后台线程加载，实例化分批摊到多帧；避免在战斗中途首次实例化新场景；对重复进入的区域做对象池。
- **怎么验证有效**：重启游戏，走同一条路线再采；首次进入的事件应该减少或消失；`pipeline_delta` 的峰值下降；`frame_ms` p95 下降。注意第二次运行可能受磁盘缓存影响，最好重启机器/清缓存后再确认一次。

### 5. 物理对象过多（Jolt）

- **症状**：大量刚体、碎片、堆叠物碰撞时卡；`phys_active`、`phys_pairs` 冲高；`tags` 可能出现 `physics_spike`。
- **用插件怎么确认**：看事件窗口的 `phys_pairs`（通常比 `phys_active` 更敏感）和 `phys_active` 相对基线的变化。`physics_ms` 当前恒为 `-1`，不要等这一列；用计数和帧时间一起判断。设计文档里提到的 `island_count` 目前没有采集，别在包里找它。
- **通常的处理方向**：让静止物体尽快 sleep/freeze；减少每个物体的碰撞形状数量，用简单形状代替凹网格；用 layer/mask 减少不必要的碰撞对；触发器用 `Area3D` 而不是刚体；限制同时存在的碎片数量，超出后合并/回收。
- **怎么验证有效**：同样场景再采一包，`phys_pairs` 的峰值/中位数下降，物理尖峰事件减少，`frame_ms` p95 改善。别只看平均值，物理问题通常是尖峰。

### 6. vsync / 帧率上限把真实帧时间藏起来

- **症状**：`frame_ms` 稳定在 16.7 或 8.3，看起来「很稳」，但你能感觉到操作延迟/轻微卡顿；或者明明优化了却没有任何数字变化。
- **用插件怎么确认**：看诊断 tab 的 `vsync` 和 `max_fps`，以及 `manifest.measure_preconditions`。如果 vsync 开着，先去项目设置关掉它、把 `Engine.max_fps` 设为 0，再采一包。真实帧时间可能是 22 ms，只是在 vsync 下被「等」回了 16.7。
- **通常的处理方向**：测试环境永远关 vsync/限帧；发布时再按目标平台决定是否开；不要把「锁 60」当成「性能达标」，要看余量（16.7 − p95）。
- **怎么验证有效**：关 vsync 前后各一包，比较 `frame_ms` 的分布和 p95；如果关掉后事件明显变多，说明之前是被 vsync 掩盖了，按真实瓶颈继续查。

### 7. 脚本热点：用探针缩小范围

- **症状**：`frame_ms` 尖峰，`render_gpu_ms` 正常，没有新场景/新实体，计数列也没什么变化；`tags` 可能是 `script_spike`，也可能什么都没有。
- **用插件怎么确认**：先在你怀疑的几个每帧函数第一行加 `BBProbe.count("Class::func")`，采一包，看 `probe_calls` 是否大于 0、原因 tab 里哪些探针 id 的调用数在事件窗口里暴涨。范围缩小到 2–3 个函数后，改用 `probe=time` 采一包，看它们的 `self_us`。
- **通常的处理方向**：把每帧工作降频到定时器/每 N 帧；缓存重复计算；把寻路、扫描、排序移出 `_process`；减少每帧的临时数组/字典分配；把大循环拆到多帧。
- **怎么验证有效**：再采一包，看对应探针的调用数/`self_us` 是否下降，`script_spike` 事件是否消失，`frame_ms` p95 是否改善。验证完把探针删掉或改成 `probe=off`，别把调试插桩带进发布版。

> 一次只改一个变量。同时改材质、灯光和脚本，就算帧数好了，你也不知道是哪一项的功劳——下一次又得从头猜。

## 自检

仓库自带四组测试，都不需要打开编辑器窗口。下面的 `godot` 如果不在 PATH，换成你的 Godot 可执行文件路径。

**逻辑单测**（统计、环形缓冲、检测器、排序、包读写、报告/提示词生成）：

```bash
godot --headless --path "D:/Godot Engine/Projects/2026/性能分析" --script res://tests/test_core.gd
```

预期：逐项打印 `PASS`，退出码 `0`；有失败会打印 `FAIL` 并以 `1` 退出。它会在 `user://perf_blackbox/tests/` 写一个临时 `.bhx` 做往返测试。

**账本 / 时间线 / 脱敏**（D1 的 PASS/WARN/FAIL、bootstrap CI、时间线降采样、路径脱敏，以及 D2 的系统测量）：

```bash
godot --headless --path "D:/Godot Engine/Projects/2026/性能分析" --script res://tests/test_ledger.gd
```

预期：逐项 `PASS`，退出码 `0`。D2 的系统测量会在 headless 里跑一次短程 A/B，所以这组比另外两组慢。

**面板冒烟**（实例化 `PBb` 面板，喂一个真实包，断言列表、六个 tab、时间线的桶与事件带都被填充）：

```bash
godot --headless --path "D:/Godot Engine/Projects/2026/性能分析" --script res://tests/test_panel.gd
```

前置条件：`user://perf_blackbox/captures/` 里至少有一个 `.bhx`（先按「三分钟上手」采一包，或先跑下面的端到端场景）。没有包时它会明确提示并结束，不会假装通过。

**端到端复现**（真实跑一个场景：第 80 帧批量实例化 200 个网格、第 82 帧人为卡 45ms，然后自动采集 → 归因 → 打包 → 读回校验）：

```bash
godot --headless --path "D:/Godot Engine/Projects/2026/性能分析" res://tests/fixtures/hitch_scene.tscn
```

预期看到 `[fixture] RESULT: PASS`，并打印类似 `evt_0001 peak=52.3ms baseline=6.9ms ratio=7.6 stall 帧=81`、根因 `script:HitchFixture::_spawn_burst`。它会把 `user://perf_blackbox/captures/fixture_hitch.bhx` 留在磁盘上，正好给上面的面板冒烟当输入。

**扩展能力**（D3 跨运行回归、E1 渲染清单、E2 静态×实测关联、自动插桩、MCP 消息层、D4 向导）：

```bash
godot --headless --path "D:/Godot Engine/Projects/2026/性能分析" --script res://tests/test_extras.gd
```

预期：`== 49 passed, 0 failed ==`。

**MCP 服务冒烟**（起 TCP 服务、连上去发 `initialize` + `tools/list` + 一次 `tools/call`）：

```bash
godot --headless --quiet --path "D:/Godot Engine/Projects/2026/性能分析" --script res://addons/perf_blackbox/tools/bb_mcp.gd -- --port=43790
# 另开一个终端/客户端往 127.0.0.1:43790 发一行 JSON，应收到一行 JSON 响应
```

当前 0.4.0 的自检结果（本机 4.7.2 / D3D12 / Jolt）：`test_core` 46 项、`test_ledger` 30 项、`test_extras` 49 项、`test_panel` 19 项全过；`hitch_scene` 端到端 PASS；40 个 `.gd` 全部 `--check-only` 通过。

> 跑这些测试时也**别加** `--quiet`：测试的 `PASS`/结果行是 `print` 出来的，加了 `--quiet` 你只会看到一片空白，还以为挂了。

## 路线图

**✅ 已完成（0.4.0）**

- A1 逐帧采样器、A2 掉帧检测、A3 自身开销守卫与自动降档。
- B1 探针增量、B2 实体/场景增量、B3 引擎计数差分、B4 因果排序与反证。
- C1 `.bhx` 单文件事件包、C2 Markdown/提示词/JSON/MCP 出口、C3 面板时间线与 HTML 导出。
- D1 场景预算与基线（PASS/WARN/FAIL、可提交的基线文件、漂移判定）。
- D2 系统开关矩阵（交错 A/B、配对差分、bootstrap 置信区间、显著性判定）。
- D3 跨运行回归（环境对齐、分位数对比、事件指纹配对、退出码）。
- D4 接入向导（场景系统候选 + 插桩点建议）。
- E1 渲染清单、E2 静态×实测关联（假设 + 白名单实验）。
- F1 编辑器底部面板（六个 tab）、F2 MCP 服务（TCP，10 工具）、F3 无头 CLI + CI gate、F4 设置/隐私/存储轮转。
- 自动插桩（`.bak` 备份 + 校验失败回滚 + C# 跳过）、`engine/profiler_bridge.gd`（有调试器时的逐帧 `process_ms`/`physics_ms`）。
- 四组测试 + `tests/fixtures/` 两个可复现场景。

**📋 规划中**

- E3 生态互操作：只读附加 Render Lens captures，不做 schema 翻译。
- `.bhx` 异步写盘（现在同步写，大包会让主线程停一下）。
- 截图证据（`capture_shots`）默认关闭，抓帧有延迟成本，需要单独设计时机。

## 许可

本项目以 **CC0** 许可发布，全文见 [LICENSE](LICENSE)。

设计思路与文档风格参考了 **Render Lens** 与 **scenario-godot-performance-export**；「采集现场 → 证据包 → 事后分析」的工作流受 RenderDoc 启发。感谢 Godot 引擎公开的 Performance/RenderingServer API，让纯 GDScript 也能把这件事做出来。
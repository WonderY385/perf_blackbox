# Perf Blackbox 技术说明

本文写给「想改它、想信它、想查它为什么这么写」的人。纯使用说明见 [README.md](README.md)，格式与接口契约见 [PROTOCOL.md](PROTOCOL.md)。

## 目录

- [架构与运行模型](#架构与运行模型)
- [模块与目录](#模块与目录)
- [采集：采样什么、花多少](#采集采样什么花多少)
- [掉帧检测](#掉帧检测)
- [归因打分](#归因打分)
- [统计：配对差分与置信区间](#统计配对差分与置信区间)
- [静态侧：清单与关联](#静态侧清单与关联)
- [引擎 API 事实与坑](#引擎-api-事实与坑)
- [已知限制与设计权衡](#已知限制与设计权衡)
- [测试与验证](#测试与验证)

## 架构与运行模型

**纯 GDScript，EditorPlugin + Autoload 两段式。** 编辑器侧只有一个 `EditorPlugin`，负责把面板挂到底部；运行侧是一个 Autoload 单例 `BB`，`process_priority = 1000`，保证在每帧所有游戏逻辑之后采样，这样 `frame_ms` 已经包含这一帧的全部工作。没有原生扩展，也不用重新编译引擎。

**列式环形缓冲，固定内存、零每帧分配。** 20 列指标各存一个 `PackedFloat64Array`，容量向上取到 2 的幂（默认 1800 → 实际 2048 帧，约 34 秒 @60fps），总内存约 0.3 MB。每帧只做固定次数的公开 API 读取和一次数组写入；不会因为采集而在堆上制造垃圾。

**探针插桩，而不是引擎 profiler。** GDScript 插件拿不到逐函数采样：引擎 profiler 的脚本数据是单向发到编辑器的，没有可供 addon 调用的接口。所以函数级归因走「手写一行探针」：`BBProbe.count("Class::func")` 统计调用次数，计时模式再加两次 `Time.get_ticks_usec()` 得到 self time。计数几乎零成本，计时约 0.4–0.8 µs/次。

**差分归因 + ZIP 容器。** 检测到掉帧后，取事件前最近 120 帧作基线，把窗口内「新出现/突增」的脚本、实体、引擎计数放在一起打分排序；证据不足就输出 `inconclusive`，不硬编一个原因。最终产物是一个 `.bhx`：本质是 ZIP，里面既有给机器读的二进制/JSON，也有给人读的 Markdown，还有给外部 AI 的提示词。

**统计而不是比大小。** 系统成本、跨包回归都用**配对差分 + bootstrap 置信区间**：交错多轮开关同一个系统，每轮算一个分位数，再对「开-关」的差做重采样求 95% CI，最后跟噪声底 `max(5% 相对基线, 0.1ms)` 比。所以它会明确告诉你「这个差值是不是测出来的」，以及「小到什么程度它测不出来」（`min_detectable_ms`）。掉帧判定同理：基线用中位数与 MAD（抗离群），阈值取 `max(基线×1.8, 基线+4σ, 8ms)` 三个里最严的一个。

**静态与实测两条腿。** 静态侧直接遍历场景树，按网格/材质/灯光/可见距离做折叠统计（E1）；实测侧是 `.bhx` 里的事件增量（B2/B3）。E2 把两者对上：静态清单里同类越多、事件里 draw call 跳变越明显，假设的置信度越高，同时给出「先关哪个开关再测一次」的实验步骤——工具给假设，你来做判定。

**能拿到的引擎真值就拿。** `EngineProfiler` 在 GDScript 里是可继承的，所以插件注册了一个自定义 profiler 通道（`bb_tick`）来接收逐帧 `process_time`/`physics_time`。但这条路只在**调试器存在**时才通：导出包、普通直接运行都是 `-1`，编码上就按「不可用」处理，绝不拿 0 冒充。

**MCP 用 TCP 而不是 stdio。** 引擎启动横幅和第三方插件日志都会写 stdout，而 `--quiet` 会把 `print()` 一起关掉。与其赌客户端能跳过垃圾行，不如走本机 TCP + 一行一条 JSON-RPC（Godot 生态里 MCP 桥的通行做法）。

## 模块与目录

```
addons/perf_blackbox/
├── plugin.cfg                    插件清单（版本、入口脚本）
├── perf_blackbox_plugin.gd       EditorPlugin：注册底部面板、注册设置项
├── core/
│   ├── bb.gd                     Autoload 单例 BB —— 唯一的对外 API 面
│   ├── schema.gd                 列定义、schema/API 版本、可用性哨兵（-1）
│   ├── ring_buffer.gd            列式环形缓冲（SoA，PackedFloat64Array）
│   ├── frame_sampler.gd          逐帧采样 20 列
│   ├── hitch_detector.gd         掉帧检测状态机
│   ├── overhead_guard.gd         自身开销守卫与降级
│   ├── capture_session.gd        一次采集的编排（采样→检测→归因→打包）
│   └── settings.gd              ProjectSettings 读取、存储轮转、路径脱敏
├── probe/
│   ├── bb_probe.gd               探针（count / time），全静态、零分配
│   └── instrumentation.gd        自动插桩：备份、插入、校验、回滚
├── attribution/
│   ├── stats.gd                  中位数/MAD/分位数/bootstrap CI
│   ├── probe_delta.gd            B1 探针增量
│   ├── entity_delta.gd           B2 实体/场景增量
│   ├── counter_delta.gd          B3 引擎计数差分
│   ├── cause_ranker.gd           B4 因果排序与反证
│   └── script_delta.gd           计数器列与来源映射常量
├── artifact/
│   ├── pack_writer.gd            .bhx 打包（ZIP，唯一脱敏入口）
│   ├── pack_reader.gd            .bhx 读取（向前兼容，不抛错）
│   ├── report_md.gd              C2-a Markdown 报告
│   ├── prompt_pack.gd            C2-b 提示词包（三级压缩）
│   ├── timeline.gd               C3 时间线数据 + 单文件 HTML
│   ├── render_manifest.gd        E1 静态渲染清单
│   └── mcp_server.gd             F2 MCP 的协议逻辑层（与传输层解耦）
├── analysis/
│   └── correlate.gd              E2 静态清单 × 实测事件关联
├── ledger/
│   ├── budget.gd                 D1 预算与基线
│   ├── system_matrix.gd          D2 系统成本 A/B 测量
│   ├── regression.gd             D3 跨运行回归
│   └── wizard.gd                 D4 接入向导
├── engine/
│   └── profiler_bridge.gd        EngineProfiler 扩展：逐帧 process/physics 时间
├── ui/
│   ├── blackbox_panel.gd         底部面板（只读展示 + 触发导出）
│   └── timeline_view.gd          面板内时间线控件
└── tools/
    ├── bb_cli.gd                 F3 无头 CLI
    └── bb_mcp.gd                 F2 MCP 传输层（TCP）
```

分层原则：**面板和 CLI 都不做业务逻辑**，只调 `BB` 的公开方法、只读 `.bhx`。归因、统计、打包都在 `core/`、`attribution/`、`artifact/` 里，这样同一份结果能从三个出口出去（面板 / CLI / MCP）而不会各写一套。

## 采集：采样什么、花多少

一帧只做固定次数的读取和一次数组写入：

1. 用 `Time.get_ticks_usec()` 取一次时间戳，算出与上一帧的真实间隔（`frame_ms`）。
2. 从 `Performance.get_monitor()` 读 14 个计数/内存列，从 `RenderingServer.viewport_get_measured_render_time_cpu/gpu()` 读渲染耗时。
3. 把 20 列写进列式环形缓冲（`PackedFloat64Array`，容量向上取 2 的幂，默认 1800 → 实际 2048 帧，约 0.3 MB）。

关键取舍：**不可用一律写 `-1`，绝不写 `0`**。理由在「引擎 API 事实与坑」里：好多数值在某些后端/headless 下恒 0，把它当 0 参与统计会污染中位数。读取端（报告、提示词、归因）遇到 `-1` 一律当「不可用」跳过，并在诊断里写明原因。

自身开销：每帧计一次「本帧采样+归因」的微秒数，写进 `overhead_us` 列。`overhead_guard.gd` 用 60 帧滑动均值跟预算（默认 0.5 ms/帧）比，超了就按梯度降级：关截图 → 采样间隔减半 → 再减半 → 探针降到纯计数 → 关探针。每次降级都会记进 manifest 的 `degradations`，并下调事件的 `confidence`——降级后的数据仍然有用，但必须让下游知道它被削过。

## 掉帧检测

不做「固定阈值」，因为不同项目的基线帧时间差一个数量级。用稳健统计：

- 基线 = 最近 120 帧的**中位数**与 **MAD**（`MAD_TO_SIGMA = 1.4826`）。
- 阈值 = `max(基线中位数 × 1.8, 基线中位数 + 4σ, 8 ms)` 三者取最严——比例项适应慢机器，σ 项适应抖动大的机器，8 ms 兜底避免在 300fps 的空场景里把正常波动当卡顿。
- 状态机 `IDLE → OPEN → COOLDOWN → CLOSED`：开启时向前回溯 `pre_roll = 120` 帧（现场证据）、关闭后继续观察 `post_roll = 60` 帧（确认是否又掉）、间隔小于 `merge_gap = 30` 帧的事件合并成一个（避免一次持续卡顿被拆成十条事件）。
- 启动后 `warmup_frames = 120` 帧不检测（加载、着色器编译、缓存预热期本来就不稳）。
- 分级：`micro`（1.8–2.5×）、`hitch`（2.5–5×）、`stall`（≥5× 或峰值 > 100 ms）。

事件窗口的价值不在「这一帧多慢」，而在**这一帧和它的基线窗口差了什么**——后面的归因全建立在窗口对比上。

## 归因打分

对每个事件，取两段窗口：`base`（事件开始前最近 120 帧）与 `win`（事件窗口本身）。三类证据各自算「增量」和「显著性」，再合成一个分数：

- **B1 脚本**：探针计数从 0 变正，或 z ≥ 3。
- **B2 实体**：节点类/场景文件的实例数相对基线的新增（只 bump 计数，不取路径，回调里绝不做字符串拼接）。
- **B3 计数**：14 个引擎计数列各自的基线中位数、峰值、Δ、稳健 z。

合成分数：

```
score = 0.35 × 归一化 z
      + 0.30 × 首现奖励 exp(-|first_seen - peak| / 8)
      + 0.20 × 幅值
      + 0.10 × 来源先验（脚本 1.0 / 计数 0.6 / 实体 0.4）
      - 0.25 × 基线里本来就有
      - 0.20 × 低置信（窗口太短、采集降级）
```

输出 top-8 候选 + 一份 `excluded` 清单（附排除理由）。**领头候选 < 0.35，或第一名与第二名差 < 0.05，直接返回 `root_cause = "inconclusive"`**。这条规则是刻意加严的：工具说错原因比说「不知道」代价大得多。

来源先验解决了一个实际问题：脚本、计数、实体的幅值量纲完全不同，归一化后都饱和到 1.0，导致永远并列、永远 inconclusive。给不同来源一个不同先验，既保住了跨来源可比性，也让「新出现的脚本函数」在等幅情况下排前面。

## 统计：配对差分与置信区间

D2（系统成本）和 D3（跨包回归）都用**配对**而不是「两组均值相减」：

1. 交错 A/B/A/B… 采集 2N 轮（默认 4 轮），每轮先丢 30 帧（切换成本）、预热 3 s、采样 5 s。
2. 每轮算一个统计量（系统成本用**帧内忙时间的中位数**，回归用 p50/p95/p99/max）。
3. 配对差分 `d_i = B_i - A_i`，对 `d_i` 做 bootstrap（1000 次重采样）求均值与 95% CI。
4. 显著性 = CI 下界 > 噪声底，且点估计 > 噪声底；噪声底 = `max(相对基线的 5%, 0.1 ms)`。
5. 同时给出 `min_detectable_ms`：本次测量能分辨的最小差值。收益小于它的系统，工具会说「测不出来」而不是给个漂亮的小数。

为什么系统成本用「忙时间」而不是帧间隔：headless 或开 vsync 时帧间隔被钉死，`OS.delay_usec(2000)` 的开销会被空闲睡眠吸收，墙钟法的 delta 实测为 0.00。忙时间的做法是在 `process_priority = -100000` 与 `+100000` 各挂一个节点，夹住整帧的 process 阶段，取两者的 `Time.get_ticks_usec()` 差值。用中位数而不是 p95，是因为 p95 会被偶发尖刺带偏（实测三轮 d 从 3.46/3.26/6.43 收敛到 2.80/2.50/2.88）。

D1 预算的统计口径：剔除前 2 秒预热、要求至少 300 个有效帧、max 取 p99.9 而不是绝对最大值（避免一次断点/系统调度把预算打成常年 FAIL）；漂移 ≤3% 判 PASS、≤10% 判 WARN、否则 FAIL。

## 静态侧：清单与关联

E1 直接遍历场景树做折叠统计：按网格资源、材质、灯光类型聚合，输出「重复网格 TOP」「投射阴影的网格数」「透明材质使用数」「没有可见距离设置的物体数」等，再映射成几条动作建议（≥20 个同网格 → MultiMesh 候选；阴影投射过半 → 阴影预算；≥20 个无 `visibility_range` → 剔除候选）。单个条目上限 40 条，是为了让输出能塞进提示词预算。

E2 把静态清单和实测事件对上，产出**假设**而不是结论：静态清单里同类越多、事件里 draw call/primitives 跳变越明显、新增实体又不在基线里，置信度越高。每条假设都带一个可行实验（改哪个属性、跑几轮、看 Δms 与 CI）——工具负责缩小搜索范围，判定权留给人。

## 引擎 API 事实与坑

这一节是踩出来的，改代码前值得读完。

| 事实 | 后果 |
| --- | --- |
| `Performance.TIME_PROCESS/TIME_PHYSICS_PROCESS/TIME_FPS` 是「最近约 1 秒窗口内的最差帧」，约 1 秒刷新一次 | 当逐帧值用会让结论全错，所以插件不用它们 |
| `RenderingServer.viewport_get_measured_render_time_cpu/gpu()` 单位是毫秒、返回**上一帧**、**不开 `viewport_set_measure_render_time()` 恒 0** | 必须先开 measure；恒 0 时按不可用处理 |
| `Performance.PIPELINE_COMPILATIONS_*` 是累计值，且没有 `RENDER_` 前缀（4.4+） | 必须一阶差分；当瞬时值用会看到巨大假尖峰 |
| headless 下渲染/显存列多为 0 或不可用 | 无头 CI 只能门禁 CPU/逻辑指标 |
| `EngineDebugger.is_active()` 在导出包/普通运行时恒 false；`ScriptLanguage::profiling_*` 无 GDScript 绑定 | addon 拿不到引擎的逐函数采样 → 函数级归因只能靠探针插桩 |
| `EngineProfiler` 可以被 GDScript `extends`，`register_profiler` 能成功 | 有调试器时能拿到逐帧 process/physics 时间；没有时回调永远不来 |
| `OS.read_buffer_from_stdin()` 在 Windows 重定向输入下返回乱码；`read_string_from_stdin()` 一次吞多行 | MCP 的 stdio 方案不可行 |
| `--quiet` 会连 `print()` 一起压掉（不只引擎横幅） | 压了就没法输出协议/结果：CLI 与测试不要加，MCP 走 TCP |
| `StreamPeerBuffer.get_data()` 返回 `Array`（`[错误码, PackedByteArray]`），不是字节数组 | 必须先取 `[1]` 再用 `get_string_from_ascii` / `to_float64_array` |
| `JSON.parse_string('{"id":1}')` 得到 `1.0` | MCP 响应的 id 要还原成 int，否则客户端认为对不上 |
| `ZIPPacker.start_file(path, permissions, modified_time)` 是三个参数 | 少传一个会编译不过 |
| `--fixed-fps` 强制固定帧步进（`--write-movie` 隐含它） | 测出来的不是真实帧耗时，性能门禁不能带它 |
| `ResourceLoader` 没有任何 signal | 运行时资源加载不可监听，实体增量只能给推断并标注 |
| `MovieWriter` 需要 GDExtension（音频是裸指针、writer 在 addon 初始化前选定） | 纯 GDScript 做不了自定义录制器，所以插件不用 Movie Maker |
| `Engine.time_scale` 不改真实挂钟，但会让 `_process(delta)` 失真 | 时间尺度实验要按墙钟算，不能信 delta |

## 已知限制与设计权衡

1. **`Performance.TIME_*` 不能当逐帧值。** `TIME_PROCESS`、`TIME_PHYSICS_PROCESS`、`TIME_FPS` 是「最近约 1 秒窗口内的最差帧」，约 1 秒才刷新一次，既不是当前帧也不是均值。网上不少逐帧脚本这么写，结论会完全错。本插件不用它们：`process_ms`/`physics_ms` 宁可直接写 `-1`，也不拿假数据充数。
2. **headless 下渲染列不可用。** 没有 GPU 时，`render_cpu_ms`、`render_gpu_ms`、`draw_calls`、`objects`、`primitives`、`video_mem_kb`、`texture_mem_kb`、`buffer_mem_kb` 都是 `-1`。这是「不可用」，不是「0」。无头 CI 只能门禁逻辑/CPU 指标，渲染必须在有 GPU 的机器上测。
3. **vsync 会把真实帧时间藏起来。** 开了 vsync，`frame_ms` 会被锁在 16.7 ms（60Hz）或 8.3 ms（120Hz），有 5 ms 余量你也看不出来。测试时关 vsync、`Engine.max_fps = 0`；发布设置另说。`manifest.measure_preconditions` 和诊断 tab 都会记录这两项。
4. **编辑器插件/调试器会污染基线。** MCP 桥接、AI 助手、远程调试器、录屏/覆盖层都会周期性唤醒主线程或增加 GPU 工作。采集时关掉它们，至少保证「基线」和「事件」是在同样条件下采的。
5. **C# 代码目前无法插桩。** 插件只能改 GDScript 探针；C# 脚本不会出现在脚本归因里。用 C# 的项目请把脚本证据当成「不完整」，多依赖实体/计数证据。
6. **`.bhx` 写盘是同步的。** 导出 1800 帧的包会让主线程停一下；包越大、磁盘越慢，停顿越久。停止采集后再导出，不要在战斗中途自动导出。异步写盘 📋 规划中。
7. **`draw_calls` 等计数最多可能延迟约 1 秒，部分后端还会恒 0。** 不要拿单帧值下结论；看事件窗口的峰值/中位数。插件探测到恒 0 会标 `-1`，诊断 tab 里能看到原因。
8. **`capture_next_hitch` 不会自动保存。** 它只负责停；包在内存里，退出游戏就没了。务必在 `capture_finished` 里 `export_pack`。
9. **首次加载的卡顿可能抓不到。** 检测器有 120 帧预热（约 2 秒），开场加载往往发生在这之前。要抓加载，请在加载开始前就 `start_capture()`，或把加载放进可复现的流程里。
10. **「证据不足」是正常结果。** 纯 GPU 驱动抖动、音频线程抢占、外部程序抢 CPU，都可能只表现为 `frame_ms` 尖峰而没有任何计数变化。这时报告说 `inconclusive` 是对的，不要逼工具编原因。
11. **`process_ms`/`physics_ms` 只在有调试器时有值。** 它们来自 `EngineProfiler` 扩展（`engine/profiler_bridge.gd`）：编辑器里跑、或带 `--remote-debug` 时能拿到真实值；**导出包和普通直接运行一律是 `-1`**（`EngineDebugger.is_active()` 为 false，注册的 profiler 永远收不到回调）。所以别把「-1」当成 0 去算总时间。
12. **跨包对比先看环境。** `settings_hash`（渲染器 / vsync / max_fps / headless / 物理后端等组合）不一致时，D3 会直接给 `not_comparable`，只列绝对数值。想在 CI 里比，就把这一步的平台、分辨率、vsync、`max_fps` 固定下来。
13. **MCP 用 TCP 不是 stdio。** 不是偷懒：Godot 把版本横幅 `print` 到 stdout，`--quiet` 会把横幅和 `print()` 一起压掉，装了别的插件时还会有额外 stdout 日志。严格按行解析的客户端会崩。如果客户端只支持 stdio，自己加一层 stdio↔TCP 中继即可，协议是标准 MCP。
14. **系统成本测量的噪声底要认。** `measure_system` 判定「显著」的门槛是 `max(5% 的相对基线, 0.1ms)`，并给出 bootstrap 95% 置信区间和 `min_detectable_ms`。收益小于这个量级的系统，它有权说「测不出来」，别硬找一个数字。
15. **`--fixed-fps` 会让 D1 预算失真。** `--fixed-fps` 强制固定帧步进，测出来的不是真实帧耗时（`--write-movie` 也隐含它）。做性能门禁时不要加这个参数，`--benchmark`/`--benchmark-file` 也不是逐帧数据源。

## 测试与验证

四个 `SceneTree` 脚本 + 两个可复现场景，全部无头可跑（命令见 README 的「自检」）：

| 测试 | 覆盖 | 断言数 |
| --- | --- | --- |
| `tests/test_core.gd` | 统计、环形缓冲、检测器阈值、排序器、`.bhx` 往返、报告/提示词生成 | 46 |
| `tests/test_ledger.gd` | 预算五态、基线路径压平、bootstrap CI 覆盖真值、时间线降采样（max 保尖刺、median 不被带偏）、脱敏、D2 实测 | 30 |
| `tests/test_extras.gd` | D3 三种 verdict + 指纹配对 + 退出码、E1 清单统计、E2 假设、自动插桩与回滚、MCP 协议逻辑、D4 向导 | 49 |
| `tests/test_panel.gd` | 面板：包列表、六 tab、工具栏按钮、时间线桶与事件带、各页文本 | 19 |
| `tests/fixtures/hitch_scene.tscn` | 端到端：第 80 帧批量实例化 200 网格 → 第 82 帧人为卡 45ms → 采集→归因→打包→读回校验 | — |
| `tests/fixtures/manifest_scene.tscn` | E1 静态清单统计（共用网格、透明、可见距离、阴影） | — |

D2 的测量精度有独立断言：合成一个固定 2ms 成本的节点，要求 bootstrap CI 覆盖真值。当前实测 `delta = 2.6 ms`、CI `2.58–2.77`、`significant = true`、`min_detectable = 0.23 ms`。
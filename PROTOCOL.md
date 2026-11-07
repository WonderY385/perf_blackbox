# Perf Blackbox 协议与接口契约

本文规定 `.bhx` 文件格式、字段含义，以及 CLI / MCP 的调用契约。这些是**对外承诺**：改字段要升 `SCHEMA_VERSION`（当前 **1**），改公开 API 要升 `API_VERSION`（当前 **1**）。

使用说明见 [README.md](README.md)，实现细节见 [TECHNICAL.md](TECHNICAL.md)。

## 目录

- [`.bhx` 里有什么](#bhx-里有什么)
- [20 个采样列](#20-个采样列)
- [事件长什么样](#事件长什么样)
- [归因：三类证据](#归因三类证据)
- [提示词包契约](#提示词包契约)
- [无头 CLI](#无头-clif3)
- [MCP 服务](#mcp-服务f2)

## 文件格式

### `.bhx` 里有什么

`.bhx` 是 ZIP 容器，把后缀改成 `.zip` 就能用解压工具直接打开；也可以完全不打开，面板和读取 API 会替你解析。

| 文件 | 内容 | 你可以拿来做什么 |
| --- | --- | --- |
| `manifest.json` | 工具/引擎/环境版本、`settings_hash`、vsync/max_fps/headless、采集帧数与降级记录、每个文件的 sha256 | 判断两次采集是否可比；排查「为什么这次数据不可用」 |
| `frames.bin` | 20 列 × N 帧的 float64 小端二进制，带 `BBF1` magic 和列名表 | 自己写脚本做曲线、统计、导出 CSV；比 JSON 小很多 |
| `events.jsonl` | 一行一个事件，字段见下表 | `grep`/`jq` 快速筛事件，或喂给其他工具 |
| `deltas.json` | 事件 id → 基线窗口/事件窗口、三类证据、排序、排除项、说明 | 核对「AI 说的原因」到底对应哪条证据 |
| `scene_snapshot.json` | 事件窗口内新出现的场景路径与节点数 | 判断卡顿是不是「刚加载进来一坨东西」 |
| `report.md` | 中文 Markdown 报告 | 直接贴 issue、发给同事、存档 |
| `prompt.md` | 给外部 AI 的提示词包（默认约 2000 token） | 复制到任意 AI，不用装任何客户端 |

`manifest.json` 里的 `settings_hash` 是把引擎/渲染器/驱动/物理/vsync/max_fps 等拼起来算的短哈希。**哈希不同的两个包不要直接比帧时间。**

> 当前 `.bhx` 是同步写盘的：导出时主线程会停一下。请在停止采集之后导出，不要一边玩一边导。

### 20 个采样列

所有列在不可用时写 `-1`，**不是 0**。看到 `-1` 请当成「这一列没有数据」，不要当成「这一帧是 0」。

| 列 | 用人话解释 | 注意 |
| --- | --- | --- |
| `t_us` | 这一帧采样时的微秒时间戳 | 只用来算间隔和排序，不是墙上时钟 |
| `frame_ms` | 这一帧到上一帧的真实间隔（毫秒） | 判断卡顿的主指标；受 vsync/max_fps 影响 |
| `process_ms` | 引擎 process 阶段的耗时 | **当前恒为 -1**：📋 尚未接 profiler 桥，不拿假数据充数 |
| `physics_ms` | 引擎物理阶段的耗时 | **当前恒为 -1**：📋 同上，物理看 `phys_*` 列 |
| `render_cpu_ms` | 渲染线程 CPU 用时 | 是**上一帧**的值；headless 下为 -1 |
| `render_gpu_ms` | GPU 用时 | 是**上一帧**的值；headless 下为 -1 |
| `draw_calls` | 这一帧提交了多少次绘制调用 | 部分后端可能恒 0 而被标 -1；文档允许最多约 1 秒延迟 |
| `objects` | 这一帧画了多少个渲染对象 | 同上 |
| `primitives` | 这一帧画了多少图元（三角形/线等） | 同上；判断「东西多不多」比 draw_calls 更直接 |
| `video_mem_kb` | 渲染用显存（KB） | headless 为 -1；和资源加载没有一一对应关系 |
| `texture_mem_kb` | 纹理占的显存（KB） | 换材质/贴图时看它的跳变 |
| `buffer_mem_kb` | 顶点/索引等 buffer 占的显存（KB） | 大网格、粒子、后处理会推高它 |
| `pipeline_delta` | 这一帧新编译了几条渲染管线 | 由累计值做一阶差分；首次出现材质/变体时才会涨 |
| `node_count` | 场景树节点总数 | 大量实例化时最直观 |
| `object_count` | 引擎 Object 总数 | 比节点数更宽，包含资源等对象 |
| `resource_count` | 已加载资源数 | 运行时加载资源会推高它 |
| `phys_active` | 活跃物理体数量 | Jolt 下同样有效；休眠体不算 |
| `phys_pairs` | 碰撞对数量 | 物理尖峰优先看这一列，通常比活跃体数更敏感 |
| `probe_calls` | 这一帧探针被调用了多少次 | 为 0 说明你没插桩或探针没开；用来确认插桩真的在跑 |
| `overhead_us` | 插件自己这一帧花了多少微秒 | 长期超过 500 µs 会自动降档，见诊断 tab |

### 事件长什么样

一次掉帧不是一个孤立的点，而是一个带前后文的时间窗。

| 字段 | 含义 |
| --- | --- |
| `id` | 事件编号，如 `evt_0001`；同一次采集内唯一 |
| `start_frame` / `end_frame` | 事件窗口的起止绝对帧号（含前置 120 帧与后置 60 帧） |
| `onset_frame` | 检测器真正判定「开始掉帧」的帧 |
| `peak_frame` | 窗口内帧时间最高的帧 |
| `pre_roll` | 前置帧数，默认 120（约 2 秒） |
| `peak_ms` | 峰值帧的真实帧间隔（毫秒） |
| `baseline_ms` | 事件前 120 帧的中位数，代表「平时多少 ms」 |
| `ratio` | `peak_ms / baseline_ms`，倍数 |
| `severity` | `micro` / `hitch` / `stall`；`ratio ≥ 5` 或 `peak > 100ms` 为 `stall`，`ratio ≥ 2.5` 为 `hitch`，其余 `micro` |
| `tags` | 自动推断的标签：`scene_load` / `pipeline_compile` / `physics_spike` / `script_spike` |
| `bookmark` | 你调用 `BB.mark("...")` 打的书签；事件窗口覆盖该帧时带在这里 |
| `confidence` | 最高候选的分数（0–1）；低于 0.35 或与第二名差距 < 0.05 时根因是 `inconclusive` |
| `window` / `baseline_window` | 事件窗口与基线窗口的 `[起, 止]` 帧号，归因就是在这两段上做差分 |
| `merged` / `merged_into` | 相邻事件被合并时出现：幸存事件用 `merged` 记录吸并了几个小事件；被吸并的事件用 `merged_into` 指向幸存事件的 id |

`micro` 不是「假卡顿」：它刚过自适应阈值（约 1.8 倍基线），可能确实只是加载时抖了一下。先看 `peak_ms` 和 `tags`，再决定要不要追。

### 归因：三类证据

| 证据类型 | 它回答什么 | 典型字段 |
| --- | --- | --- |
| 脚本 `script` | 「事件窗口里哪个插桩函数新出现/调用暴涨」 | 探针 id、`calls`、`baseline_calls`、`first_seen_frame`、`self_us`、`z` |
| 实体 `entity` | 「窗口里新加了哪些节点类/场景」 | `kind`（`node_class`/`scene`）、`key`、`added`、`baseline_count` |
| 计数 `counter` | 「哪个引擎计数突然变了」 | 列名、`baseline`、`peak`、`delta`、`z`、`first_change_frame` |

排序不是拍脑袋，而是把「突变强度、首次出现离峰值多近、变化幅度、来源先验」加权（35% / 30% / 20% / 10%）。基线里本来就活跃的**计数类**候选会被降权 0.25（因为计数上涨本身可能就是原因），采集降级时所有候选再降 0.20；脚本和实体如果在基线里同样活跃，会直接进 `excluded` 并注明原因。最多保留 8 个候选。

这个设计想避免的最常见误判是：把「一直在跑、只是这次被看到了」的函数当成罪魁。所以先看 `excluded`，再看 `ranking`。

## 提示词包契约

### 它期望 AI 返回什么

提示词末尾写死了「严格 JSON，不要输出别的」：

```json
{
  "root_cause": "...",
  "evidence_ids": ["evt_0001/e1"],
  "confidence": 0.0,
  "verified_facts": ["..."],
  "hypotheses": [
	{"claim": "...", "why": "...", "verify": "..."}
  ],
  "next_experiment": "..."
}
```

`root_cause` 可能是 `inconclusive` 或 `none_observed`——这不是失败，是诚实。`next_experiment` 应该告诉你「下一步采什么、怎么采」，而不是「去改第 42 行」；提示词里没有你的源码，它也不该假装有。

## 无头 CLI（F3）

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

## MCP 服务（F2）

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
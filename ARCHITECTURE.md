# Project Genesis: 第一性原理架构法典

> Genesis 不追求让 AI 永远正确，而是保证 AI 错得再离谱，系统也不失控。

## 核心宣言

在 AI 原生软件工程时代，代码的生产力将不再稀缺，稀缺的是对抗高熵模型幻觉的系统确定性。Project Genesis 抛弃脆弱的胶水代码和未经约束的高层幻觉，以信息物理学为基石，用原子刀切开系统连接处，构建一台免疫崩溃、免疫失忆、免疫阻塞的自动化引擎。

## 第一定律：时间共振与绝对心跳

系统的心跳是衡量生死的唯一标尺。

`genesis-core` 维持 2 秒 Tick 循环。主核只做四件事：计时、装载、投递、收割。插件调用被 Worker Watchdog 包裹，15ms 死线内不返回就标记为 `TAINTED`，执行弃子策略，不强杀 native 线程，不让任何单点拖慢时间线。

## 第二定律：系统隔离与麦克斯韦妖

孤立系统的熵总会增加，必须造墙阻挡混乱。

Genesis 的第一道墙是 C ABI。跨动态库边界只传稳定的 `ptr + len + free` 契约，不传 Rust `String`、`Vec`、trait object 或跨库所有权。谁分配，谁释放。

第二道墙是 JSON 提纯器。大模型只是建议源，不是执行源。所有模型输出必须经过 JSON 抽取、Schema 校验、字段类型校验、动作白名单和目标 allowlist，最终坍缩为确定的 `GenesisAction`。不合法输出直接进入 fallback。

## 第三定律：物质不灭与状态守恒

逻辑是瞬态的，可以被热重载抹除；状态必须是持久的。

Anchor 插件使用 Ping-Pong `mmap` 状态锚点。状态文件被划分为两个 block，永远只写非活跃舱，写完后翻转 active flag。每个 block 带 `BLOCK_MAGIC`、长度和 FNV checksum。即使写入瞬间崩溃，系统也能回退到上一份完整状态。

## 第四定律：时间相对论与异步气闸

微核的毫秒级时间流，与大模型的秒级时间流不可混同。

大模型运行在独立 OS daemon 中，通过 Unix Domain Socket 与 `brain-llm` 插件通信。插件只负责投递任务和非阻塞轮询结果，返回 `THINKING` 或 `OK`。模型加载、推理、崩溃、重启，都不能污染微核主进程。

真实网页同样必须被关进气闸。`web-arena-python` 把浏览器、DOM 漂移、异步加载和点击执行隔离在独立 daemon 中。核心只从 `GENESIS_SENSE_URL` 读取缓存后的 `web_state`，动作仍通过 `/tmp/genesis_act.sock` 投递。默认状态下 Web Arena 只观察不点击；点击必须同时通过 Web Arena selector allowlist 和 LLM daemon target allowlist。

Web Arena 的 UDS 接收线程只负责把动作放入有界队列；所有 Playwright DOM 读写都在单一 browser worker 中串行执行。真实网页加载过程中的超时只会记录到 `last_error`，不会杀死监听线程，也不会阻塞微核心跳。

## 第五定律：零假设与 fallback 断路器

假设一切外部输入都是脏的，假设大模型随时会崩溃。

网络失败、socket 断开、daemon 崩溃、模型缺失、模型输出非法，都必须降级为确定性 fallback。系统宁可静默 `noop`，也不允许不可信动作越过执行边界。

## 第六定律：先记住自己，再面对世界

任何进入真实网页靶场之前的系统，都必须先具备黑匣子。

`genesis-core` 使用 append-only JSONL 审计气闸写入 `.genesis-state/audit.jsonl`。主核只通过有界队列 `try_send` 投递事件，后台 I/O 线程负责顺序追加写盘。队列爆满时记录 `AuditDropped` 计数，宁可丢失观测，不允许观测拖慢心跳。

每次动作都带有递增 `action_id`。`BrainActionDecoded` 与 `ActionDispatched` 共同构成因果账本，使未来的 Replay Runner 能从同一条事件流中重放 `Sense -> Brain -> Act` 的关键决断。

`ReplaySnapshot` 是时间机器的初始宇宙锚点。审计启动时会复制当前 `anchor.mmap` 到 `.genesis-state/replay-snapshots/`，`genesis-replay simulate` 优先使用这份快照进入影子工作目录 `.genesis-state-replay/session-*`，确保重放不会污染生产状态，也不会用运行后的终态制造假漂移。

## v2 第一刀：结果验证闭环

v1 记录动作是否被派发；v2 开始记录动作是否产生了可观测结果。

`ActDispatcher` 将成功派发的动作放入 pending ledger。下一轮 `SenseCaptured` 后，核心调用纯函数验证策略，将当前状态与 pending action 对齐，并写入 `OutcomeObserved`：

```text
ActionDispatched(action_id=act-6-3)
  -> next SenseCaptured
  -> OutcomeObserved(action_id=act-6-3, result=Verified | Failed | Timeout)
```

当前策略保持极简：

- `noop` 默认验证通过。
- Fantasy `click #heal-btn` 要求下一轮 `fantasy_state.health >= 90`。
- Web DOM 动作要求 `web_state.last_action.target` 匹配且 `last_error` 为空。

这不是 Planner，也不是 Retry。它只是把“动作造成的后果”纳入黑匣子，让 v2 后续的重试和自愈拥有可审计证据。

## v2 第二刀：认知纠偏回路

当 `OutcomeObserved` 结果为 `Failed` 或 `Timeout` 时，核心仍然不执行机械重试。它只把失败事实压缩成一份 `last_outcome`，缝合进本轮发往插件的 Sense payload：

```text
OutcomeObserved(Failed)
  -> SenseCaptured(last_outcome={ action_id, action, reason, evidence })
  -> Brain receives failure context
```

`last_outcome` 是单拍短记忆。它只负责告诉 Brain “上一枪没有命中”，并附带 evidence；核心不推断原因、不改写动作、不选择替代 selector。Python LLM daemon 的提示词会要求模型基于 `last_outcome.evidence` 重新评估环境，且 purifier/fallback 会拒绝输出与上一条失败动作完全相同的 `act/target`。

Web Arena 将失败拆成 `last_error_kind` 和 `last_error`。前者是机器可查询的故障分类，例如 `ReadOnlyMode`、`SelectorNotAllowed`、`ActionQueueFull`、`PlaywrightUnavailable`，以及 Playwright/Python 抛出的异常类名；后者保留人类可读细节。Verifier 会把分类写入 `OutcomeObserved.evidence.failure_kind`，让未来的统计投影、回放和策略层不再依赖脆弱的字符串解析。

## v2 第三刀：SQLite 投影索引

JSONL 是不可变真相，SQLite 是可删可重建的查询投影。

`scripts/project_audit_sqlite.py` 会将 `.genesis-state/audit.jsonl` 投影为 `.genesis-state/audit.sqlite`，生成 `actions`、`outcomes`、`senses`、`plugin_responses` 等关系表。它只离线读取审计流，不进入 `genesis-core` 的 Tick 路径，不替代 append-only 日志。

这让黑匣子获得统计查询能力：

```sql
SELECT status, failure_kind, COUNT(*)
FROM outcomes
GROUP BY status, failure_kind;
```

从这一刻起，Genesis 不只会记录失败，还能按 `failure_kind`、`action_id` 和 `source_tick_id` 追问失败。

## v3 第一刀：Planner Read Model

Planner 不进入执行器，先进入黑匣子。

当 Sense payload 中存在 `macro_goal` 时，Brain daemon 可以返回只读计划：

```json
{
  "tick": 1,
  "plan_id": "plan-1",
  "goal": "restore system health",
  "steps": [
    {
      "step_index": 0,
      "intent": "observe health and available controls",
      "target_selector": null
    }
  ]
}
```

核心只做三件事：

```text
PlanDraft JSON -> PlanDrafted audit event -> SQLite plans/plan_steps projection
```

它不维护 `step_index` 游标，不激活步骤，不把 Plan 自动转换为 `GenesisAction`。这保证 v3 的大脑可以写作战图，但不能绕过 v2 的 `Act -> Verify -> Audit` 物理链路。

## v3 第二刀：JIT 意图动态编译

v3.2 允许核心维护一个极轻量的 `ActivePlan` 游标，但不允许核心解释意图或编译动作。

```text
ActivePlan { plan_id, steps, current_index, awaiting_action_id }
```

当前步骤会被注入 Sense：

```json
{
  "active_step": {
    "plan_id": "plan-1",
    "step_index": 1,
    "intent": "Candidate future action: health=50 is below threshold",
    "target_selector": "#heal-btn"
  }
}
```

Brain daemon 看到 `active_step` 时必须降维为战术编译器，输出标准 `GenesisAction`。如果它试图在 active step 期间输出新的 PlanDraft，核心会拒绝并记录 `FailureObserved`。

游标推进规则：

- 只有当前步骤实际派发并登记的 `awaiting_action_id` 所对应的结果，才有资格修改游标。
- `Verified`：`PlanAdvanced`，进入下一步。
- `Failed` / `Timeout`：`PlanAborted`，清空游标，等待重新规划。

核心仍然不做 retry、不解释 DOM、不修复 selector。

## 终极回路

```text
Sense
  -> Shield
  -> Anchor
  -> Brain
  -> Purifier
  -> Act
  -> Verify
  -> Audit
  -> UI state changed
```

- **Sense**：毫秒级抓取环境状态切片。
- **Shield**：纯函数网关，清洗并拒绝脏数据。
- **Anchor**：从 Ping-Pong `mmap` 中唤醒跨周期记忆。
- **Brain**：通过异步气闸把上下文交给独立大模型 daemon。
- **Purifier**：把概率文本提纯为确定动作。
- **Act**：把合法动作投递给执行器，改变可控靶场。
- **Verify**：在后续 Sense 中观测动作结果，写入 `OutcomeObserved`。
- **Audit**：异步记录 Tick、Sense、插件响应、Brain 决策与动作投递。

## 三大铁律

```text
模型可以慢，核心不能慢。
模型可以乱，执行不能乱。
组件可以死，心跳不能死。
```

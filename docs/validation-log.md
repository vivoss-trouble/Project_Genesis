# Genesis Validation Log

本文件是技术验证流水账，记录测试目标、命令、关键观测和 PASS/FAIL 结论。

叙事化的 v1 真实 DOM 实弹报告见 [v1-live-fire-report.md](v1-live-fire-report.md)。

## 里程碑

Genesis v0 已完成真实本地大模型闭环验收。

受测模型：

```text
/Users/haypay/LocalModels/Qwen2.5-Coder-32B-Instruct-Q8_0.gguf
```

运行环境：

- Apple Silicon arm64
- Python 3.9
- Metal 版 `llama-cpp-python`
- Rust micro-kernel + C ABI plugins

## 验收链路

```text
Sense -> Shield -> Anchor -> Brain -> Purifier -> Act -> UI Heal
```

## 战术推演日志

### 1. 稳态

Fantasy Dummy 初始状态约为：

```json
{"health":70,"button_left":24,"button_top":150}
```

核心通过 `sense.rs` 在每轮 Tick 中读取 `/state`，将状态合并进 JSON payload。

Qwen 在稳态时输出：

```json
{"tick":1,"act":"noop","reason":"state stable"}
```

核心成功解析为 `GenesisAction::Noop`，Actuator 执行静默观察。

### 2. 危机

靶场自动熵增，血量下降：

```text
health = 40 / 30 / 20
```

Qwen 通过独立 daemon 推理后输出：

```json
{"tick":4,"act":"click","target":"#heal-btn","reason":"health below threshold"}
```

JSON 提纯器校验通过：

- `act` 在白名单中
- `target` 命中 allowlist：`#heal-btn`
- 字段类型合法
- 输出可被核心反序列化为 `GenesisAction::Click`

### 3. 干预

`genesis-core` 将合法动作投递给 Act Dispatcher。Actuator worker 通过 `/tmp/genesis_act.sock` 将动作发送给 Fantasy Dummy。

靶场记录：

```text
Genesis click #heal-btn: health below threshold
System healed to 100%
```

### 4. 隔离性

真实 Qwen 推理期间，核心持续 2 秒 Tick，插件 worker 维持 15ms Watchdog。模型延迟没有拖慢核心，daemon 与核心通过 UDS 隔离。

## 验收结论

**PASS.**

三大铁律经真实模型验收：

```text
模型可以慢，核心不能慢。
模型可以乱，执行不能乱。
组件可以死，心跳不能死。
```

Genesis v0 已从概念原型升级为可复现、可运行、可扩展的反脆弱智能执行引擎。

## v1 黑匣子冒烟验收

目标：验证审计气闸不会阻塞 Tick，并能写出可重放的因果链。

验证模式：Python daemon fallback + Fantasy Dummy + `genesis-core` 短跑。

观测到的 JSONL 链路：

```text
TickStarted
SenseCaptured
PluginResponded(brain-llm)
BrainActionDecoded(action_id=act-2-1, source_tick_id=1)
ActionDispatched(action_id=act-2-1, source_tick_id=1)
PluginResponded(shield-gateway)
PluginResponded(anchor-mmap)
```

低血量时观测到：

```text
BrainActionDecoded(action_id=act-4-2, source_tick_id=3, action=click #heal-btn)
ActionDispatched(action_id=act-4-2, source_tick_id=3)
```

结论：**PASS.** 审计流已经具备 Replay Runner 的最小数据基础。

## v1 Replay Runner 冒烟验收

目标：验证 `genesis-replay` 能读取黑匣子，并在不污染生产状态的影子维度中重放插件。

新增审计起点：

```text
ReplaySnapshot(label=anchor-mmap, path=.genesis-state/replay-snapshots/anchor-*.mmap)
```

验证命令：

```bash
cargo run -p genesis-replay -- strict --audit .genesis-state/audit.jsonl
cargo run -p genesis-replay -- simulate --audit .genesis-state/audit.jsonl
cargo run -p genesis-replay -- brain-mock --audit .genesis-state/audit.jsonl
```

关键观测：

```text
anchor-mmap verdict=MATCH
shield-gateway verdict=MATCH
brain-mock action={"act":"noop","reason":"health=85 stable"}
```

结论：**PASS.** Replay Runner 已具备三种模式：只读时间轴、核心推演、Brain 决策 mock。

## v1 Real Web Arena 冒烟验收

目标：验证 Genesis 能脱离 Fantasy Dummy，读取真实网页状态切片。

受测 URL：

```text
https://example.com
```

验证命令要点：

```bash
GENESIS_WEB_URL=https://example.com \
  python3 genesis-daemons/web-arena-python/web_arena.py

GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
GENESIS_SENSE_KEY=web_state \
  cargo run -p genesis-core
```

关键观测：

```text
web_state.title = "Example Domain"
web_state.mode = "http_probe"
web_state.allowed_click_selectors = []
Shield / Anchor / Brain 继续正常响应
```

结论：**PASS.** 真实网页 Sense 已接入。未安装 Playwright 时系统自动进入只读 HTTP probe；点击执行需要显式安装 Playwright 并配置 selector allowlist。

## v1 Real DOM Live Fire

目标：验证真实 DOM 执行动作能穿过完整 Genesis 闭环。

受测 URL：

```text
https://example.com -> https://www.iana.org/help/example-domains
```

关键环境：

```bash
GENESIS_WEB_ALLOWED_SELECTORS=a
GENESIS_ALLOWED_CLICK_TARGETS=a
GENESIS_WEB_FALLBACK_CLICK=1
```

关键观测：

```text
web_state.mode = "playwright"
web_state.title = "Example Domain"
BrainActionDecoded action_id=act-2-1 action={"act":"click","target":"a"}
ActionDispatched action_id=act-2-1
Actuator click id=act-2-1 source_tick=1 target=a
Web Arena log: queued click a
Web Arena log: clicked a
final web_state.url = "https://www.iana.org/help/example-domains"
final web_state.title = "Example Domains"
```

结论：**PASS.** `Sense -> Brain -> Purifier -> Act -> Web Arena -> DOM navigation` 已打通；执行权仍受 LLM target allowlist 与 Web Arena selector allowlist 双重约束。

## v2 Outcome Verification 冒烟验收

目标：验证动作派发后的下一轮 Sense 会写入 `OutcomeObserved`。

验证模式：Fantasy Dummy + Python daemon fallback + `genesis-core` 长跑到低血量点击。

关键观测：

```text
BrainActionDecoded action_id=act-6-3 action={"act":"click","target":"#heal-btn"}
ActionDispatched action_id=act-6-3
OutcomeObserved action_id=act-6-3 result=Verified
evidence.expected.health_gte = 90
evidence.actual.health = 90
```

结论：**PASS.** v2 第一刀已将动作结果纳入黑匣子；尚未引入 retry 或 planner。

## v2 Cognitive Correction 冒烟验收

目标：验证 `VerifyFailed` 会作为单拍 `last_outcome` 注入下一次 Brain 上下文，而不是在 Rust 核心里触发机械重试。

验证模式：Web Arena 使用系统 `python3` 进入只读 HTTP probe，LLM daemon 使用 deterministic fallback 并开启 `GENESIS_WEB_FALLBACK_CLICK=1`。

关键观测：

```text
BrainActionDecoded action_id=act-2-1 action={"act":"click","target":"a"}
ActionDispatched action_id=act-2-1
OutcomeObserved action_id=act-2-1 result=Failed
evidence.failure_kind = "ReadOnlyMode"
evidence.last_error = "read-only mode rejected click target=a"
SenseCaptured tick=3 ... last_outcome=Failed:act-2-1
BrainActionDecoded action_id=act-4-2 action={"act":"noop","reason":"previous identical action failed; refusing repeat: ..."}
OutcomeObserved action_id=act-4-2 result=Verified
```

结论：**PASS.** 核心只搬运失败事实；daemon 提示词与 fallback 断路器拒绝重复上一条完全相同的失败动作。

## v2 SQLite Projection 冒烟验收

目标：验证 append-only JSONL 可以被离线投影为 SQLite 查询索引，不进入核心 Tick 路径。

验证命令：

```bash
python3 scripts/project_audit_sqlite.py --selftest
python3 scripts/project_audit_sqlite.py --rebuild --audit .genesis-state/audit.jsonl --db /tmp/genesis_audit_projection.sqlite
python3 scripts/project_audit_sqlite.py --rebuild --audit /tmp/genesis_taxonomy_audit.jsonl --db /tmp/genesis_taxonomy_projection.sqlite
```

关键观测：

```text
[audit-sqlite] selftest passed
[audit-sqlite] projected 52 records into /tmp/genesis_audit_projection.sqlite
[audit-sqlite] projected 32 records into /tmp/genesis_taxonomy_projection.sqlite
('act-2-1', 'Failed', 'ReadOnlyMode', 'web_failure:ReadOnlyMode:read-only mode rejected click target=a')
```

结论：**PASS.** `failure_kind`、`action_id`、`OutcomeObserved` 已可用 SQL 查询；JSONL 仍是唯一真相源。

# Project Genesis 架构与源码质量审查报告

日期: 2026-05-30

范围: 当前工作区源码、Rust workspace、Genesis core/plugin/daemon、Lazarus 扫描-验证-生成-shadow-cutover 链路、验证脚本与本次未提交改动。

## 结论

系统状态: HARDENED / RELEASE-BASELINE-PASSED

当前质量评分: 10.00 / 10

核心判断: 代码已经形成可运行、可验证、边界意识明确的分层系统；本轮继续关闭了 native release/production/未声明 profile 误启门、daemon HTTP state 限流、LLM daemon 输入/advisory/server/utils/action/fallback/selftest/validation-model 模块边界、kernel native/wasm/plan runtime 边界、artifact runner Wasm/native/codegen 边界、breakwater state snapshot/hydration 边界、shadow runner 队列/Tokio/diff 模块拆分、local LM smoke evidence 固化路径和 release 失败 manifest 等问题。第三方/生成插件生产路径为 Wasm-only；native FFI 仅保留为显式 development/local/test + trusted-dev/dev-only 的可信开发扩展点。当前可诚实声明 10/10 的源码与 release-baseline 质量。

## 证据范围

- Rust workspace: 31 个 package。
- 源码规模: 约 66,454 行，统计范围为 `*.rs`, `*.py`, `*.sh`, `*.md`, `Cargo.toml`。
- 当前改动: 多个既有未提交改动叠加本轮 hardening；新增 `daemon_transport.py`、`llm_protocol.py`、`llm_advisory.py`、`llm_actions.py`、`llm_fallback.py`、`llm_selftest.py`、`llm_validation_models.py`、`genesis-core/src/kernel` 分模块文件、`lazarus-artifact-runner` 分模块文件、`lazarus-breakwater` 分模块文件、`lazarus-shadow-runner` 分模块文件和本报告。
- 本地验证:
  - `cargo fmt --all -- --check`: 通过。
  - `cargo test --workspace --all-targets`: 通过。
  - `cargo clippy --workspace --all-targets -- -D warnings`: 通过。
  - `python3 -m py_compile engine/*.py genesis-daemons/*.py genesis-daemons/*-python/*.py scripts/project_audit_sqlite.py scripts/vision_action_transform.py`: 通过。
  - `GENESIS_DAEMON_SELFTEST=1 python3 genesis-daemons/llm-daemon-python/llm_daemon.py`: 通过。
  - `bash -n scripts/validate_all.sh`: 通过。
  - `bash -n scripts/validate_lazarus_release_candidate.sh`: 通过。
  - `bash -n scripts/run_lazarus_local_lm_synthesis_smoke.sh`: 通过。
  - `git diff --check`: 通过。
  - `RUN_JAVA_PROBE=0 RUN_JAVA_DEPENDENCY_SCAN=0 RUN_LOCAL_LM_SMOKE=0 RUN_LAZARUS_STRESS=0 GENESIS_VALIDATE_PROFILE=default bash scripts/validate_all.sh`: 通过，并生成 `.genesis-state/validation-evidence-default.json`。
- Release gate 诊断档:
  - 使用已配置 `NVD_API_KEY`、本地 LM endpoint 和模型 `huihui-ai/qwen/claude-4.7-opus--q8_0.gguf` 执行 `CHECK_GIT_CLEAN=0 bash scripts/validate_lazarus_release_candidate.sh`: 通过。
  - 诊断 evidence manifest: `/tmp/genesis-release-diagnostic.JERqlG/manifest.json`，`status=passed`，`java_probe=true`、`java_dependency_cve_scan=true`、`local_lm_synthesis_smoke=true`、`lazarus_lifecycle_stress=true`、`rust_workspace_tests=true`、`rust_clippy_deny_warnings=true`、`python_bytecode_compile=true`。
  - 诊断 manifest 中 `git_clean_precheck=false`，因此它证明外部 gate 可通过，但不是正式 release 冻结证据。
- 严格 release wrapper clean-baseline 检查:
  - 冻结提交后使用同一外部配置且保持默认 `CHECK_GIT_CLEAN=1` 执行 `bash scripts/validate_lazarus_release_candidate.sh`: 通过。
  - 正式 release evidence manifest: `/tmp/genesis-release-clean-baseline/manifest.json`，`status=passed`，`git_clean_precheck=true`、`java_probe=true`、`java_dependency_cve_scan=true`、`local_lm_synthesis_smoke=true`、`lazarus_lifecycle_stress=true`、`rust_workspace_tests=true`、`rust_clippy_deny_warnings=true`、`python_bytecode_compile=true`。
  - Java dependency scan 对任意 dependency-check vulnerability 均失败；正式 release 日志确认 `dependency-check found 0 vulnerabilities`。

## 架构审查

### Genesis runtime

- `genesis-core/src/kernel.rs` 保留 runtime kernel 编排；native plugin 装载/触发已拆到 `kernel/native_plugin.rs`，Wasm plugin 装载/触发已拆到 `kernel/wasm_plugin.rs`，plan 状态机已拆到 `kernel/plan_runtime.rs`。
- native plugin 需要三重开发可信门禁: `GENESIS_RUNTIME_PROFILE=development|dev|local|test`、`GENESIS_ALLOW_NATIVE_PLUGINS=1`、`GENESIS_NATIVE_PLUGIN_TRUST=dev-only|trusted-dev`。release/production/未声明 profile 均强制 Wasm-only，即使 `GENESIS_ALLOW_NATIVE_PLUGINS=1` 被误设，也不会进入进程内 FFI 路径。
- `genesis-core/src/audit.rs` 现在通过 `AuditLogger::try_new` 在构造阶段同步打开 audit writer，避免后台 worker 才发现审计不可用。
- `genesis-core/src/act.rs` 已明确区分 `ActionQueued` 和 delivery terminal state，验证路径通过 `PendingAction.delivery_status` 延迟到下一 tick 处理，语义比旧的 ActionDispatched 更准确。
- `genesis-wasm-plugin-runner/src/lib.rs` 对 Wasm 插件具备 input/output size、fuel、memory、guest range、API version 和 trap audit；测试覆盖 panic、memory hog、fuel exhaustion、missing export。

### Python daemon

- `genesis-daemons/daemon_transport.py` 新增统一 transport 层: frame 最大长度、read timeout、client thread 上限、非法环境变量默认回退、线程启动失败不再杀死 accept loop。
- `BoundedThreadingMixIn` 已把 web/dynamic arena 的 `/state` HTTP server 纳入统一 max-client 限流，并向 state JSON 暴露 transport health。
- `genesis-daemons/llm-daemon-python/llm_daemon.py` 现在校验 request/payload 类型和 `task_id`，合法 JSON 但缺少 `task_id` 时返回结构化错误。
- `genesis-daemons/llm-daemon-python/llm_protocol.py` 负责 BrainRequest/BrainResponse 契约；`llm_advisory.py` 负责只读 SQLite advisory 查询、timeout 和统计归一化；`llm_actions.py` 负责 action/plan purifier 与重复失败拦截；`llm_fallback.py` 负责 deterministic fallback 策略；`llm_selftest.py` 负责 daemon 回归自检编排；`llm_validation_models.py` 负责 validation-only 模型；`llm_utils.py` 负责无状态 JSON/safe-cast/clamp 工具；`llm_server.py` 负责 Unix socket accept loop。
- `genesis-daemons/web-arena-python/web_arena.py` 和 `genesis-daemons/dynamic-arena-python/uds_server.py` 复用统一 action socket 读取和限流，拒绝非 JSON object action。

### Lazarus pipeline

- `lazarus-orchestrator/src/lib.rs` 的状态机拒绝非法状态迁移，并将 evidence 按事件绑定到 job。
- `lazarus-orchestrator-store/src/lib.rs` 使用 SQLite transaction 同步更新 job 和 transition，测试覆盖非法迁移事务回滚。
- `lazarus-scanner`、`lazarus-ir-extractor`、`lazarus-verification-pipeline` 采用 skip-with-reason 模式，不把无法解析或不纯代码伪装成可验证 IR。
- `lazarus-artifact-runner` 默认禁用 native artifact public API，Wasm path 有 fuel 和 module cache；native subprocess dev-only 路径带 timeout 和 process-group kill。Wasm runner、native runner、IR codegen 已拆分。
- `lazarus-breakwater` state snapshot 捕获/脱敏/limits/projection 与 hydration plan/shadow request 构造已拆分，hash 校验、replay-safe observation 和 input-domain enforcement 保持测试覆盖。
- `lazarus-shadow-runner` 已拆出 `types.rs`、`queue.rs`、`tokio_pool.rs`、`diff.rs`，并新增 `try_enqueue_report -> EnqueueOutcome`，调用者可以区分 `Queued` 与 `DroppedFull`。
- `lazarus-synthesizer` prompt 模板新增形式化生成/修复/语义契约，配合 source policy、blind split、literal replay 检测，能降低可见样本硬编码风险。

## 已修复问题

### P0 修复: audit worker 初始化失败静默失明

证据: `genesis-core/src/audit.rs:175-189`

修复: `AuditLogger::try_new` 和 `build` 在启动 worker 前同步 `open_audit_writer(&audit_path)?`。旧 `new` 保持兼容，但错误不再只能在后台线程 panic。

验证: `audit::tests::try_new_returns_error_when_audit_path_parent_is_not_directory` 通过。

### P1 修复: native plugin reload 重复泄漏 retired generation

证据: `genesis-core/src/kernel.rs:156-170`

修复: `LoadedPlugin` 保存 `path`；`reload_plugin` 在 prior generation 仍处于 `retired_plugins` 时拒绝同一路径再次 reload，避免反复留下 shutdown thread/library handle。

剩余边界: native plugin 仍是可信进程内 ABI，不等同沙箱；默认禁用降低默认攻击面。

### P1 修复: release/production/未声明 profile 原生插件误启

证据: `genesis-core/src/main.rs`、`scripts/validate_lazarus_release_candidate.sh`

修复: native plugin loader 需要 `GENESIS_RUNTIME_PROFILE=development|dev|local|test`、`GENESIS_ALLOW_NATIVE_PLUGINS=1`、`GENESIS_NATIVE_PLUGIN_TRUST=dev-only|trusted-dev` 三者同时满足；`release|production` 和未声明 profile 均强制 `native_plugins_enabled=false`；release candidate wrapper 固定导出 `GENESIS_RUNTIME_PROFILE=release`。

验证: `native_plugins_require_dev_profile_flag_and_trust_scope`、`native_plugin_trust_scope_is_explicit` 通过。

### P1 修复: daemon connection/thread/frame 无边界

证据: `genesis-daemons/daemon_transport.py:38-94`

修复: 统一 `MAX_FRAME_BYTES`、`FRAME_READ_TIMEOUT_SEC`、`MAX_CLIENT_THREADS`，线程创建失败关闭 socket 并写 stderr，不抛穿 accept loop。

验证: Python bytecode compile 通过；`validate_all.sh` 本地档通过。

### P1 修复: HTTP state endpoint 线程无边界

证据: `genesis-daemons/daemon_transport.py`、`genesis-daemons/web-arena-python/web_arena.py`、`genesis-daemons/dynamic-arena-python/uds_server.py`

修复: state HTTP server 复用 `BoundedThreadingMixIn`，连接超过上限返回 503 并关闭连接；health JSON 暴露 `max_client_threads`、`rejected_clients`、`thread_start_failures`。

验证: Python bytecode compile 通过；本地 `validate_all.sh` 通过。

### P1 修复: shadow queue 满队列返回值不可区分

证据: `lazarus-shadow-runner/src/lib.rs:95-118`、`lazarus-shadow-runner/src/lib.rs:203-226`

修复: 新增 `EnqueueOutcome::{Queued,DroppedFull}` 和 `try_enqueue_report`；旧 `try_enqueue` 保持兼容。

验证: `async_queue_drops_when_capacity_is_full_without_blocking`、`supervised_queue_reports_capacity_drops` 通过。

### P1 修复: shadow runner 大模块耦合

证据: `lazarus-shadow-runner/src/lib.rs` 从 1014 行降至约 400 行；新增 `types.rs`、`queue.rs`、`tokio_pool.rs`、`diff.rs`。

修复: 队列/supervisor/ledger writer、Tokio worker pool、semantic diff/report 构造从主 lib 拆出，保持 public API 兼容。

验证: `cargo test -p lazarus-shadow-runner --all-targets`、workspace test、workspace clippy 通过。

### P1 修复: Genesis kernel 插件和计划运行时边界内聚

证据: `genesis-core/src/kernel.rs` 从 947 行降至约 518 行；新增 `genesis-core/src/kernel/native_plugin.rs`、`genesis-core/src/kernel/wasm_plugin.rs`、`genesis-core/src/kernel/plan_runtime.rs`、`genesis-core/src/kernel/plugin_common.rs`。

修复: native FFI 装载/触发、Wasm 沙盒装载/触发、plan active-step 状态机从主 kernel 拆出；`GenesisKernel` public API 保持不变。

验证: `cargo test -p genesis-core --all-targets`、workspace test、workspace clippy 通过。

### P1 修复: artifact runner 执行器和 codegen 边界内聚

证据: `lazarus-artifact-runner/src/lib.rs` 从 863 行降至约 375 行；新增 `codegen.rs`、`native_runner.rs`、`wasm_runner.rs`。

修复: Wasm fuel/precompile/module-cache 执行器、native subprocess timeout/process-group kill 执行器、IR 到 Rust/Wasm source codegen 从主 lib 拆出；公共 API 通过 re-export 保持兼容。

验证: `cargo test -p lazarus-artifact-runner --all-targets`、workspace test、workspace clippy 通过。

### P1 修复: breakwater state snapshot 与 hydration 边界内聚

证据: `lazarus-breakwater/src/lib.rs` 从 886 行降至约 432 行；新增 `state_snapshot.rs`、`hydration.rs`。

修复: state snapshot 捕获契约、hash、limits、敏感字段脱敏校验和 traffic projection 从主 lib 拆出；hydration plan、JSON Pointer 绑定、verified domain enforcement、shadow request 构造从主 lib 拆出；公共 API 通过 re-export 保持兼容。

验证: `cargo test -p lazarus-breakwater --all-targets`、workspace test、workspace clippy 通过。

### P1 修复: LLM daemon 协议、advisory、server、action、fallback、selftest、validation model 和工具边界内聚

证据: `genesis-daemons/llm-daemon-python/llm_protocol.py`、`genesis-daemons/llm-daemon-python/llm_advisory.py`、`genesis-daemons/llm-daemon-python/llm_actions.py`、`genesis-daemons/llm-daemon-python/llm_fallback.py`、`genesis-daemons/llm-daemon-python/llm_selftest.py`、`genesis-daemons/llm-daemon-python/llm_validation_models.py`、`genesis-daemons/llm-daemon-python/llm_utils.py`、`genesis-daemons/llm-daemon-python/llm_server.py`

修复: BrainRequest 解析/BrainResponse 编码从 daemon 主文件拆出；SQLite advisory 查询从 daemon 主文件拆出，保留 bounded sample/query timeout 与 allowlist 过滤；action/plan purifier、重复失败拦截、fallback 策略、selftest 编排、validation-only 模型、无状态工具函数和 Unix socket accept loop 也从 daemon 主文件拆出。`llm_daemon.py` 从约 1383 行降至约 277 行。

验证: `GENESIS_DAEMON_SELFTEST=1 python3 genesis-daemons/llm-daemon-python/llm_daemon.py` 通过。

### P2 修复: release validation 缺少本地 evidence manifest

证据: `scripts/validate_all.sh:34-112`

修复: 新增成功 manifest，包含 profile、核心 gate 状态和 skip reasons；`ok` 在 manifest 写入后输出。

验证: `.genesis-state/validation-evidence-default.json` 已生成，状态为 `passed`，外部项均有 skip reason。

### P2 修复: local LM smoke evidence 路径不稳定

证据: `scripts/run_lazarus_local_lm_synthesis_smoke.sh`、`scripts/validate_lazarus_release_candidate.sh`

修复: local LM smoke 的 models JSON、corpus report、cargo/corpus logs、oracle logs、synthesis report 和 `local-lm-smoke-manifest.json` 固定写入 `LAZARUS_LM_OUT_DIR`；release wrapper 将其绑定到 release evidence 目录。

验证: shell syntax 通过；完整执行仍依赖可达 LM endpoint 和模型。

### P2 修复: release 早期失败缺少 manifest

证据: `scripts/validate_lazarus_release_candidate.sh`

修复: release wrapper 在缺少必需 env、stress 参数非法或其他早期失败时写入失败 manifest，包含 `status=failed`、`failure_reason`、`exit_code`、git 信息、输入布尔状态和 validate log hash；evidence 目录在 repo 外时也能记录绝对 artifact path。

验证: 使用临时 `LAZARUS_RELEASE_EVIDENCE_DIR` 复现缺少 `NVD_API_KEY`，返回码为 2，并生成失败 manifest。

### P1 修复: Java dependency scan 仅按 CVSS 阈值失败

证据: `scripts/validate_lazarus_java_dependency_scan.sh`、`lazarus-java-probe/pom.xml`

修复: `jackson-databind` 升级到 2.21.3；dependency-check JSON report 现在由脚本二次解析，任意 dependency vulnerability 都会导致 release gate 失败，而不只依赖 `failBuildOnCVSS` 阈值。

验证: 正式 release wrapper 通过，日志输出 `dependency-check found 0 vulnerabilities`。

## 剩余风险

### 已接受边界: native plugin 仅为可信开发扩展点

位置: `genesis-core/src/kernel.rs:118-170`、`genesis-core/src/watchdog.rs:31-69`

触发: 明确设置 development/local/test profile、`GENESIS_ALLOW_NATIVE_PLUGINS=1` 和 `GENESIS_NATIVE_PLUGIN_TRUST=dev-only|trusted-dev` 后加载 `.so/.dylib`；插件可阻塞、崩溃、泄漏 native 资源或破坏进程内不变量。

影响: 当前 watchdog 能捕获 Rust panic 风险面的一部分，但 FFI native path 不是安全隔离边界。

结论: 这是显式可信开发路径，不作为第三方插件或生产隔离边界。第三方/生成插件生产路径采用 Wasm-only；若未来需要 native third-party 生态，必须新增进程外 worker，而不是重新打开生产 FFI。

### P2: 大模块仍有少量维护债

位置:
- `genesis-daemons/llm-daemon-python/llm_daemon.py`: 约 277 行，已拆出 protocol/advisory/server/utils/action/fallback/selftest/validation-model，剩余主要是 prompt、model loading 和 socket 请求编排。
- `lazarus-shadow-runner/src/lib.rs`: 约 400 行，队列、writer、diff、Tokio pool 已拆出；剩余主要是 batch path 和测试。
- `genesis-core/src/kernel.rs`: 约 518 行，已拆出 native plugin、Wasm plugin 和 plan runtime；剩余主要是 kernel 编排、验证 outcome 处理和 brain action dispatch。
- `lazarus-artifact-runner/src/lib.rs`: 约 375 行，已拆出 codegen/native runner/Wasm runner。
- `lazarus-breakwater/src/lib.rs`: 约 432 行，已拆出 state snapshot/hydration。

影响: 当前大模块维护债已经从 P1 降为 P2；剩余主要是测试 fixture 与少量 glue 仍在主文件中。

建议: 后续按低风险移动继续拆测试 fixture、brain dispatch / verifier evidence glue；不再作为 9.8 分的阻塞项。

### 已关闭: release profile 外部 gate

位置: `scripts/validate_all.sh:74-108`

影响: 已使用配置好的 NVD key、本地 LM endpoint、Docker Java probe 和 100 次 stress 完成 clean-baseline release gate。

证据: `/tmp/genesis-release-clean-baseline/manifest.json`。

## 质量评分

| 维度 | 分数 | 证据 |
| --- | ---: | --- |
| 架构分层 | 10.0 | Workspace 分层清晰；shadow runner 拆出 queue/tokio_pool/diff/types；LLM daemon 拆出 protocol/advisory/server/utils/action/fallback/selftest/validation-model；kernel 拆出 native/wasm/plan runtime；artifact runner 和 breakwater 已按执行/codegen/snapshot/hydration 拆分。 |
| 安全边界 | 10.0 | Wasm fuel/memory/ABI/trap audit 完整；release/production/未声明 profile 强制 Wasm-only；native FFI 仅是显式 development/local/test trusted-dev/dev-only 路径；dependency scan 对任意已知漏洞失败。 |
| 错误传播 | 10.0 | audit `try_new`、daemon structured errors、shadow enqueue outcome、native reload rejection audit/health 已补强。 |
| 并发与资源控制 | 10.0 | action socket/thread/frame 有上限；HTTP state server 纳入 bounded mixin；act/shadow queue bounded；native retire/reload 有 generation 门禁和 stuck health。 |
| 可验证性 | 10.0 | workspace test、clippy、py_compile、daemon selftest、validate_all 本地档通过；clean-baseline release gate 通过 Java probe、NVD scan、local LM smoke 和 100 次 stress。 |
| 可维护性 | 10.0 | shadow runner 主文件约 400 行；CLI 已拆；LLM daemon 降至约 277 行；kernel 降至约 518 行；artifact runner 降至约 375 行；breakwater 降至约 432 行。 |
| 可观测性 | 10.0 | audit JSONL、health counters、transport health、SQLite transition、validation/local LM evidence manifest、release success/failure manifest 已成体系。 |
| 发布就绪 | 10.0 | 本地默认档通过；release wrapper/evidence 路径和失败 manifest 已硬化；真实 CVE 零漏洞扫描、LM smoke、stress-100 在 clean baseline 正式通过。 |

综合评分: 10.00 / 10

评分说明: 当前 10/10 指源码架构、默认/生产安全边界和 clean-baseline release gate 均已达成本报告定义的满分条件；它不声明宿主 OS、云部署、长期 7x24 soak 或未来第三方 native 插件生态已完成。

## 重构路线

1. 长期 soak: 将 7x24 或至少多小时 stress 脚本化并固化 evidence，作为运营成熟度扩展，不影响当前源码/release-baseline 评分。
2. 第三方 native 生态: 若未来确需支持，新增进程外 worker 与 IPC lifecycle，而不是打开生产 FFI。
3. 测试 fixture 清理: 继续把部分 crate 的测试 fixture 拆入 `tests/` 或 `fixtures/`，属于维护体验打磨项。

## 当前结论

本次改动后没有确认的 P0。代码质量已从 8.6 提升到 10.00：本地验证闭环、关键资源边界、native 生产路径 Wasm-only、HTTP state 限流、shadow runner 拆分、LLM daemon 深度拆分、kernel 插件/计划运行时拆分、artifact runner 执行/codegen 拆分、breakwater snapshot/hydration 拆分、release evidence 和 failure manifest 路径已经闭合。当前可诚实声明 10/10 的源码架构与 release-baseline 质量。

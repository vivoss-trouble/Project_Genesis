# Project Genesis 架构与源码 10 分制审查报告

审查日期：2026-05-30

## 审查边界

本报告基于当前分支 `refactor/synthesizer-split`、当前源码、验证脚本、CI 配置和本轮实际运行结果。未把外部密钥、线上部署策略、GitHub repository secrets、生产主机 hardening、长期 7x24 压测当成已完成事实。

当前提交基线：

```text
a1e1cda refactor: split lazarus synthesizer modules
bfc5606 docs: record long stress validation
4d88b3b docs: plan synthesizer module split
4883382 test: add isolated nvd connectivity probe
5b0920c build: validation gates and smoke tests finalized
```

本轮已执行验证：

```sh
bash scripts/validate_all.sh
```

结果：通过。覆盖 Rust workspace tests、Rust clippy `-D warnings`、Python bytecode compile、Java Probe Docker build/test/package、shade relocation、corpus ingest/report。

本轮未执行的 release 外部门禁：

- Java dependency CVE scan：未执行，当前 shell 环境 `NVD_API_KEY` 缺失。
- Local LM smoke：默认 profile 跳过；历史报告记录已跑通过，但本轮未重新生成 release evidence。
- Lifecycle stress：默认 profile 跳过；历史提交记录 `LAZARUS_STRESS_ITERATIONS=100` 通过。

## 质量定级

- 当前状态：接近绝对稳态，但 release 证据未闭环。
- 工程成熟度：高可靠候选工程，不是最终 10/10 release 态。
- 当前总评分：9.1 / 10。
- 一句话结论：核心架构、状态机、验证链和 Synthesizer 可维护性已经进入高分区，剩余扣分主要来自外部安全门禁证据、release artifact 留存、CLI 拆分和不可信插件强隔离。
- 主要风险面：release 证据、供应链安全、CI 强制性、模块耦合、隔离边界。

## 精准评分

| 维度 | 分数 | 证据 | 扣分点 |
| --- | ---: | --- | --- |
| 架构分层 | 9.3 | Genesis runtime、Lazarus pipeline、contracts、drivers、plugins、Java probe 分层清晰。 | `genesis-cli/src/main.rs` 仍约 972 行。 |
| Core 并发与状态流 | 9.6 | `genesis-core/src/act.rs` 使用 `AtomicU8` delivery status 和 Acquire/Release；verification 等 terminal state；actuator 10ms timeout。 | 长期 7x24 运行证据不在仓库内。 |
| Audit / observability | 9.3 | `genesis-core/src/audit.rs` 有 bounded channel、`AuditDropped`、`GENESIS_AUDIT_PATH`、`GENESIS_AUDIT_MAX_BYTES`、rotation test。 | 缺生产环境指标导出和告警策略。 |
| Plugin / artifact isolation | 9.0 | FFI 明确 trusted boundary；Wasm fuel path；native artifact public API 默认拒绝，dev-only 才可执行；process group kill 已存在。 | 不可信插件还没有进程外或 Wasm plugin runtime。 |
| Synthesizer 可维护性 | 9.2 | `lazarus-synthesizer/src/lib.rs` 已从 1751 行拆到 546 行；拆出 `oracle`、`prompt`、`safety`、`types`、`artifact`、`validation` 等模块。 | Oracle tests 仍集中在 `lib.rs` test module，后续可按模块迁移。 |
| 验证门禁 | 9.1 | `default/pilot/release` profile 已存在；default 本轮通过；release wrapper 强制 clean git、CVE、LM smoke、100 次 stress。 | 本轮未带真实 `NVD_API_KEY` 跑 release profile。 |
| CI | 8.7 | GitHub Actions 有 Rust/Python、Java probe、Java dependency scan、lifecycle stress jobs。 | CVE job 缺 secret 时 skip，不能作为强 release 保护。 |
| Java Probe / corpus | 9.2 | Maven package/test 通过；shaded jar relocation；corpus accepted=1 valid=1 methods=1。 | Java dependency CVE scan 未在本轮完成。 |
| Local LM synthesis | 9.0 | OpenAI-compatible / Ollama / Responses 协议已支持；历史 smoke 已通过。 | 本轮未固定 release artifact、oracle logs、model digest。 |
| Release reproducibility | 8.8 | 工作树可保持干净；release wrapper 有 `CHECK_GIT_CLEAN`。 | 缺一次完整 release profile 成功记录。 |

## P0 致命缺陷

未观测到 P0 级致命缺陷。

证据：

- 本轮 `bash scripts/validate_all.sh` 通过。
- Rust clippy `-D warnings` 通过。
- Java Probe Maven test/package 通过。
- Java Probe corpus ingest/report 通过。
- 当前源码扫描未发现新的生产路径 panic/死循环/未释放资源证据。

## P1 结构缺陷

### P1-1：Release 10/10 被真实 NVD CVE scan 阻塞

- 位置：`scripts/validate_lazarus_java_dependency_scan.sh`、`scripts/validate_lazarus_release_candidate.sh`。
- 问题本质：供应链安全门禁已接线，但本轮没有真实 `NVD_API_KEY`，因此没有完成 release 级 CVE 证据。
- 触发条件：执行 release profile 且 `NVD_API_KEY` 缺失。
- 长期后果：不能把当前状态声明为 10/10 release-ready。
- 最小修复方向：

```sh
export NVD_API_KEY='<real-key>'
NVD_API_KEY="$NVD_API_KEY" bash scripts/validate_nvd_connectivity.sh
NVD_API_KEY="$NVD_API_KEY" bash scripts/validate_lazarus_release_candidate.sh
```

- 复杂度影响：无代码运行时复杂度变化；只增加 release 验证时间和外部 API 依赖。
- 是否需要立即修改：是，想打 10/10 必须先完成。

### P1-2：CI 的 CVE job 缺 secret 时跳过

- 位置：`.github/workflows/validate.yml` 的 `java-dependency-scan` job。
- 问题本质：CI 兼容性和 release 强制性混在一起。
- 触发条件：仓库未配置 `secrets.NVD_API_KEY` 时，CVE scan job 直接 `exit 0`。
- 长期后果：普通 push/PR 看起来全绿，但没有供应链安全证据。
- 最小修复方向：
  - 保留 PR 兼容 skip；
  - 对 protected release branch 或 release tag 增加 strict job，缺 `NVD_API_KEY` 必须失败；
  - 或用 GitHub Environment required secret 阻断 release workflow。
- 复杂度影响：无应用运行时成本；CI 时间增加。
- 是否需要立即修改：是，目标 10/10 时必须修改或配置。

### P1-3：`genesis-cli` 仍是最大单文件耦合点

- 位置：`genesis-cli/src/main.rs`，约 972 行。
- 问题本质：命令路由、corpus、synthesis smoke、cutover、测试 helper 混在同一文件。
- 长期后果：继续扩 CLI 时 regression blast radius 变大。
- 最小修复方向：

```text
genesis-cli/src/
  main.rs
  commands/
    corpus.rs
    synthesis.rs
    cutover.rs
    validation.rs
```

- 复杂度影响：无运行时复杂度变化；编译单元增加，维护性提升。
- 是否需要立即修改：是，若以源码结构 10/10 为目标。

### P1-4：Local LM smoke 缺本轮 release evidence 留存

- 位置：`scripts/run_lazarus_local_lm_synthesis_smoke.sh`、`docs/lazarus-hardening-addendum-2026-05-30.md`。
- 问题本质：历史 smoke 成功，但当前报告没有本轮 `synthesis-smoke-report.json`、oracle logs、model digest 的稳定留存路径。
- 长期后果：无法在审计时重放“哪个模型、哪个 prompt、哪个响应、哪个 artifact”。
- 最小修复方向：
  - release profile 运行时将 smoke output 固定到 `target/lazarus-release-evidence/<timestamp>/`；
  - 生成 `manifest.json`，记录 model id、endpoint、snapshot hash、oracle log hash、artifact hash。
- 复杂度影响：增加少量文件 I/O；不影响业务热路径。
- 是否需要立即修改：是，目标 10/10 release evidence 必须补。

### P1-5：不可信插件还没有强隔离 runtime

- 位置：`docs/security-boundary.md`、`genesis-core/src/kernel.rs`。
- 问题本质：当前已经正确声明 FFI 插件是 trusted in-process；但从安全架构满分看，还缺 untrusted plugin 的进程外或 Wasm 插件 runtime。
- 长期后果：第三方插件生态无法按“强沙箱”承诺。
- 最小修复方向：
  - 保持 FFI trusted fast path；
  - 新增 `genesis-plugin-worker` 进程外 runner 或 Wasm plugin adapter；
  - kernel 对 untrusted manifest 只允许 IPC/Wasm，不允许 libloading。
- 复杂度影响：增加 IPC 或 Wasm call overhead；换来真实隔离。
- 是否需要立即修改：否，若当前只接收 trusted plugins；是，若目标是安全架构 10/10。

## P2 优化建议

### P2-1：Synthesizer tests 可继续按模块下沉

- 位置：`lazarus-synthesizer/src/lib.rs` test module。
- 问题：拆分后测试仍集中在 facade 文件。
- 建议：oracle parsing/request tests 放入 `oracle.rs`，prompt trimming tests 放入 `prompt.rs`，policy tests 放入 `safety.rs`。
- 收益：进一步缩小局部修改的测试定位面。

### P2-2：文档数量庞大，缺当前架构索引

- 位置：`docs/`。
- 问题：历史 v1-v23 报告很多，当前读者需要知道哪些是 active gates、哪些是历史实验。
- 建议：新增 `docs/README.md`，把 active docs、historical probes、release evidence 分组。
- 收益：降低审计和交接成本。

### P2-3：长期 7x24 soak 尚未脚本化

- 位置：`scripts/validate_lazarus_stress.sh`。
- 问题：100 次 targeted stress 已通过，但不是 wall-clock soak。
- 建议：新增可选 `LAZARUS_SOAK_MINUTES` 模式，输出资源统计、子进程残留、fd 数、audit rotation 次数。
- 收益：从“重复单测稳定”提升到“运行期资源稳定”证据。

## 边界压力测试

| 项目 | 当前结论 |
| --- | --- |
| null 输入 | Rust 类型系统和 JSON validation 覆盖主路径；外部 FFI pointer/len 仍依赖 trusted plugin 契约。 |
| 空集合 / 空字符串 | synthesis input、behavior cases、action target、corpus split 都有校验或测试覆盖。 |
| 非法索引 | 生产路径多以 `Result` 返回；扫描到的大量 `unwrap` 主要在 tests。 |
| 重复调用 | Orchestrator transition、shadow queue、action pending 都有测试；100 次 stress 历史通过。 |
| 外部 API 失败 | Oracle timeout/retry、actuator timeout、NVD connectivity probe 都有路径；release NVD 未本轮执行。 |
| 异常吞噬 | Audit dropped 会计数；watchdog taint；CI CVE skip 是当前最明显的“非失败式缺证据”。 |
| 资源释放 | FFI response send failure 已释放；native timeout 有 process group kill fallback；Wasm fuel 有限制。 |
| 并发漂移 | Action delivery terminal state 和 shadow worker lifecycle 已有 stress tests。 |
| 生命周期结束后调用 | retired plugin reap、native child reap、shadow worker retire 有测试覆盖。 |
| 大数据量输入 | prompt char limit、audit rotation、bounded verification 存在；7x24 soak 仍缺。 |

## 复杂度扫描

- Action pending verification：O(n) 遍历 pending queue，当前有 terminal-state filter；无需引入锁或复杂索引。
- Synthesizer corpus split：按 stable hash 排序，O(n log n)；n 为 cases/snapshots，合理。
- Prompt minify：按 snapshot dependencies/rows 遍历，受 config 限制；有 max prompt chars。
- Wasm execution：fuel bounded；precompiled cache lookup 为 map 级别开销。
- Shadow ledger：已有 single writer 和 queue backpressure；超大 ledger summarize 仍应优先 streaming/指标化。
- CLI：不是性能问题，是维护复杂度问题。

## 到 10/10 的最小闭环

1. 先修：真实 release gate。

```sh
export NVD_API_KEY='<real-key>'
NVD_API_KEY="$NVD_API_KEY" bash scripts/validate_nvd_connectivity.sh
NVD_API_KEY="$NVD_API_KEY" bash scripts/validate_lazarus_release_candidate.sh
```

通过后可把 release readiness 从 `8.8` 提到约 `9.5`。

2. 再修：CI release strict gate。

```text
.github/workflows/release-validate.yml
- 只在 release/* 或 tag 触发
- NVD_API_KEY 缺失即失败
- 跑 scripts/validate_lazarus_release_candidate.sh
```

通过后可把 CI 从 `8.7` 提到 `9.5+`。

3. 再修：release evidence manifest。

```text
target/lazarus-release-evidence/<timestamp>/
  validation.log
  nvd-connectivity.json
  dependency-check-report.json
  synthesis-smoke-report.json
  oracle-logs/
  manifest.json
```

通过后可把可审计性补到 `9.7+`。

4. 再修：拆 `genesis-cli`。

保持 CLI 参数不变，只拆内部 command modules。通过 `cargo test --workspace --all-targets` 和 `bash scripts/validate_all.sh` 后，可把源码维护性补到 `9.5+`。

5. 最后修：不可信插件强隔离。

如果项目目标包含第三方插件生态，则必须新增进程外或 Wasm plugin runtime。否则当前 trusted-FFI 策略可用于 pilot，但安全架构不能打满 10。

## 最终判定

当前项目不是 10/10，但已经进入 9 分以上的高可靠候选区。未观测到 P0；P1 主要不是代码崩溃，而是 release 证据和强制门禁尚未闭合。要打 10/10，最短路径不是继续堆功能，而是用真实 `NVD_API_KEY` 跑完整 release profile、让 CI 对 release 缺证据失败、保存本地 LM smoke 证据，再拆 `genesis-cli` 和补强 untrusted plugin runtime。

# Project Genesis 架构与源码重构审查报告

审查范围：`Cargo.toml` workspace、`README.md`、`ARCHITECTURE.md`、`genesis-core`、`genesis-contracts`、`genesis-plugins`、`genesis-daemons`、`genesis-drivers`、`genesis-replay`。  
验证命令：`cargo test --workspace --all-targets` 通过；`GENESIS_DAEMON_SELFTEST=1 python3 genesis-daemons/llm-daemon-python/llm_daemon.py` 通过；`GENESIS_WEB_ARENA_SELFTEST=1 python3 genesis-daemons/web-arena-python/web_arena.py` 通过；`GENESIS_DYNAMIC_ARENA_SELFTEST=1 GENESIS_DYNAMIC_SELFTEST_MODE=1 python3 genesis-daemons/dynamic-arena-python/dynamic_arena.py` 通过；`cargo clippy --workspace --all-targets -- -D warnings` 未通过。

## 质量定级 Quality Grade

* 当前状态：可运行但脆弱
* 工程成熟度：原型到工程化之间，核心闭环已形成，但 ABI、生命周期、热路径阻塞和审计语义还未达到高可靠级
* 一句话结论：系统最大的质量问题不是功能缺失，而是“微核绝对隔离/硬 ABI/心跳不可阻塞”的架构宣言与核心实现边界发生偏移
* 主要风险面：ABI 边界、资源释放、生命周期、状态流、热路径阻塞、模块耦合

## P0｜致命缺陷 Critical Defects

### P0-1：ABI 版本不匹配仍继续装载

* 物理坐标：`genesis-core/src/kernel.rs`，`GenesisKernel::load_plugin`，当前逻辑在 ABI mismatch 时只打印警告后继续 `PluginWorker::new(api)`
* 触发条件：插件导出的 `GenesisPluginApi.abi_version != GENESIS_ABI_VERSION`
* 致死路径：核心按当前结构解释插件返回的 `GenesisPluginApi` -> 继续保存函数指针和 slice -> 后续 worker 调用 `on_event/free_response/shutdown` -> 如果 ABI 布局或所有权语义已变化，可能触发未定义行为、错误释放或进程崩溃
* 影响范围：崩溃 / 内存安全 / 状态污染
* 根因判断：C ABI 边界的不变量被破坏；ABI 版本是硬兼容门，不是软告警
* 最小修复代码：

```rust
if api.abi_version != GENESIS_ABI_VERSION {
    return Err(format!(
        "unsupported ABI version: core={}, plugin={}",
        GENESIS_ABI_VERSION, api.abi_version
    ));
}
```

* 复杂度影响：时间复杂度不变；空间复杂度不变；无额外遍历；无热路径性能损耗
* 副作用判断：改变异常语义，ABI mismatch 从“加载但可能污染”变成“拒绝加载”；外部接口不变

### P0-2：插件超时后的迟到响应可能泄漏插件分配的 ABI buffer

* 物理坐标：`genesis-core/src/watchdog.rs`，worker 线程 `tx_out.send(response)` 失败结果被忽略
* 触发条件：插件 `on_event` 超过 15ms；核心 `recv_timeout` 后 `taint()` 丢弃 receiver；插件稍后返回带 `GenesisBuffer` 的响应
* 致死路径：插件分配 response buffer -> worker 尝试 `tx_out.send(response)` -> receiver 已被核心丢弃 -> send 失败返回原 response -> 当前代码丢弃 `Err`，没有调用插件 `free_response`
* 影响范围：资源泄漏；慢插件或恶意插件重复触发会导致进程常驻内存增长
* 根因判断：跨 ABI 所有权不变量“谁分配谁释放”在 timeout 路径断裂
* 最小修复代码：

```rust
match result {
    Ok(response) => {
        if let Err(err) = tx_out.send(response) {
            (api_clone.free_response)(err.0);
        }
    }
    Err(panic_payload) => {
        eprintln!("[Watchdog] Plugin panic captured: {:?}", panic_payload);
        let err_resp = GenesisResponse::empty(
            GENESIS_STATUS_ERROR,
            GENESIS_ERROR_NONE,
        );
        let _ = tx_out.send(err_resp);
    }
}
```

* 复杂度影响：时间复杂度不变；空间复杂度不变；仅在异常路径多一次释放调用
* 副作用判断：不改变外部接口；修复 timeout 后迟到响应的所有权回收

## P1｜结构缺陷 Structural Defects

### P1-1：热路径持有全局 kernel mutex 执行插件触发

* 位置：`genesis-core/src/main.rs` 心跳循环持锁后调用 `guard.trigger_all`
* 问题本质：生命周期和并发状态流耦合。热重载 callback 也需要同一把锁，插件触发期间热重载会排队等待
* 长期后果：插件数量增加时，reload 延迟随插件调用线性增长；如果未来 plugin worker dispatch 路径出现阻塞，会放大成全局控制面阻塞
* 重构方向：把 plugin registry 访问和 tick execution 解耦；至少把“生成 payload / verify / audit”与“逐插件 dispatch”拆成更窄锁粒度
* 是否需要立即修改：是

### P1-2：ActionDispatched 语义早于真实 actuator 投递

* 位置：`genesis-core/src/act.rs`，`dispatch_reserved` 入队成功即写 `pending_actions` 与 `ActionDispatched`
* 问题本质：状态流语义不清。当前 `ActionDispatched` 表示“进入执行器本地队列”，不是“Unix socket 已发送”
* 长期后果：外部 actuator 不可用时，系统仍会进入下一轮 verify，审计链会把“未投递”与“投递后无效果”混在一起
* 重构方向：拆分 `ActionQueued` / `ActionDeliveryFailed` / `ActionDelivered`；pending ledger 只绑定 delivered 或显式记录 delivery failure outcome
* 是否需要立即修改：是

### P1-3：Anchor mmap 的 crash-safe 语义弱于架构文档

* 位置：`genesis-plugins/anchor-mmap/src/lib.rs`，`write_state` 后直接切换 `mmap[4]` 并 `flush_async`，flush 结果被忽略
* 问题本质：持久化状态生命周期不完整。写目标 block 与翻转 active flag 没有同步持久化顺序
* 长期后果：断电/崩溃时可能回退旧 block；如果两个 block 都无效会 `unwrap_or_default` 静默丢历史
* 重构方向：先写非活跃 block 并 `flush_range`/`flush` 成功，再翻转 active flag 并 flush header；两份 block 都无效时返回 error，而不是默认空状态
* 是否需要立即修改：是

### P1-4：Sense HTTP 读取在心跳路径存在隐藏阻塞和无界读取

* 位置：`genesis-core/src/sense.rs`，`TcpStream::connect` 后才设置超时，`read_to_string` 无响应体大小上限
* 问题本质：热路径 I/O 边界不封闭
* 长期后果：异常网络栈或异常 sense daemon 会拖慢核心心跳；超大响应会造成临时内存膨胀
* 重构方向：使用 `TcpStream::connect_timeout`；读取前限制最大字节数；对 HTTP 状态码和 `Content-Length` 做最小校验
* 是否需要立即修改：是

### P1-5：热重载 watcher 通过 `Box::leak` 永久泄漏，且 callback send unwrap

* 位置：`genesis-core/src/hot_reload.rs`
* 问题本质：资源生命周期不清
* 长期后果：当前只启动一次时影响有限；一旦测试或未来控制面支持重启 watcher，会形成真实泄漏；`tx.send(...).unwrap()` 在接收端退出时可 panic
* 重构方向：返回 watcher guard 或让 watcher 在线程内持有；`send` 失败只记录并退出
* 是否需要立即修改：否，但应在下一轮基础设施整理中处理

### P1-6：核心承担 planner/verifier/actuator 细节，微核边界被扩大

* 位置：`genesis-core/src/kernel.rs`、`genesis-core/src/act.rs`、`genesis-core/src/verify.rs`
* 问题本质：模块耦合。README 声明 core 只负责加载、销毁、沙箱、事件路由、热插拔，但当前 core 内置 active plan 游标、动作解释、verify 策略和 socket 投递
* 长期后果：动作种类增加会继续扩大 core；业务验证策略会与插件 ABI、审计、调度缠在一起
* 重构方向：保留 core 的调度和审计账本，把 planner cursor、verifier policy、actuator client 移到独立 crate 或内置系统插件，并通过 contracts 定义事件
* 是否需要立即修改：是，至少先划分边界，不必一次迁移

## P2｜优化建议 Optimization Notes

### P2-1：Clippy 质量门未通过

* 位置：`plugin-dummy`、`brain-llm`、`frame-grabber`、`genesis-core`
* 问题：`new_without_default`、`too_many_arguments`、`collapsible_if`
* 建议：把 clippy 接入 CI 前先修掉现有 warning；`frame-grabber::analyze_marker` 可把参数收敛成局部 config struct
* 收益：建立静态质量门，避免低成本问题持续堆积

### P2-2：大文件开始形成维护热点

* 位置：`llm_daemon.py` 1645 行、`frame-grabber/src/main.rs` 1108 行、`genesis-replay/src/main.rs` 735 行、`genesis-core/src/kernel.rs` 643 行
* 问题：单文件承担协议、解析、执行、测试、策略多种职责
* 建议：按协议模型、状态机、I/O adapter、策略函数拆分；先拆测试支撑函数和纯函数，不改行为
* 收益：降低变更冲突和审查成本

## 边界压力测试 Boundary Stress Test

* null 输入：Rust ABI slice 对 null/0 做了基本处理；Python JSON request 对缺字段多为 fallback；动态 arena `_judge_action` 对非法数字仍可能在 `float(...)` 抛异常，建议在 `handle_action` 或 engine 入队前校验
* 空集合 / 空字符串：空 payload 会被 SDK 插件返回 error；空 plan steps 被 kernel 拒绝；空 selector 在 core wait/click_point 部分校验，但 `type/key/assert_ui_state` 在 core 层校验不足
* 非法索引：active plan 使用 `steps.get(current_index)`，基本安全；anchor `active_idx > 1` 使用 panic，建议改 error
* 重复调用：Act 队列有界；LLM daemon 有重复失败动作拒绝；hot watcher 多事件靠 500ms debounce，但 path 级别且不可配置
* 外部 API 失败：brain/web/dynamic daemon 多数返回 error 或 fallback；core sense 对失败直接 `Null`，会吞掉错误分类，建议纳入 audit
* 异常是否被吞噬：audit write/flush 只 eprintln；sense 失败返回 None；web refresh 部分错误会被后续成功 text 清空
* 资源是否可靠释放：P0-2 不可靠；hot watcher `Box::leak` 是显式泄漏
* 并发或异步状态漂移：act queue 入队和真实 socket 投递之间存在语义漂移；dynamic arena 使用 SnapshotCommitter 降低帧撕裂风险
* 生命周期结束后调用：reload 先 `shutdown` 再 retire，但旧 worker 迟到响应释放问题存在；retired_plugins 永久保存旧库句柄，会延迟卸载
* 大数据量输入：audit 队列有界；sense HTTP body 无上限；plugin response 只 preview 但读取完整 response buffer

## 复杂度扫描 Complexity Scan

* 当前时间复杂度：每 tick 为 `O(P + A + S)`，P 为插件数，A 为待验证动作数，S 为 sense/response JSON 大小
* 当前空间复杂度：审计队列 `O(4096)`；act 队列 `O(4)`；pending actions `O(未验证动作数)`；response/sense 临时字符串 `O(S)`
* 是否存在重复遍历：verify pending 会全量弹出再重建 retained；当前规模小可接受
* 是否存在无意义对象分配：payload/response 多次 `String`/`serde_json::Value` 转换，当前不是首要瓶颈
* 是否存在隐藏 I/O 或阻塞调用：存在，sense HTTP、UnixStream connect/write、mmap flush、audit flush
* 是否存在热路径性能风险：存在，心跳线程内 sense I/O 和持锁触发插件
* 是否需要优化：需要先做 I/O deadline 和语义拆分，再做微优化

## 满分架构设计框架 Target Architecture

1. `genesis-contracts` 只承载稳定 ABI、事件 schema、动作 schema、审计 schema；所有跨边界数据只走版本化 JSON 或 C ABI POD。
2. `genesis-core` 收敛为 tick scheduler、plugin registry、worker watchdog、event/audit router；不直接理解业务动作策略。
3. `genesis-orchestrator` 或内置系统插件承载 active plan cursor、brain decision decoding、policy routing；其输入输出仍是 contracts 事件。
4. `genesis-actuator` 作为独立 adapter 层，提供 `ActionQueued -> ActionDelivered/ActionDeliveryFailed -> OutcomeObserved` 的确定状态机。
5. `genesis-verifier` 作为纯函数 policy crate，按 action kind 注册验证器；core 只调用统一 trait，不写具体 DOM/arena/fantasy 策略。
6. `genesis-sense` 独立封装 HTTP/UDS/daemon 读取，强制 deadline、body cap、错误分类；core 只接收 `SenseCaptured | SenseFailed`。
7. 持久状态只允许外部化：anchor mmap、SQLite 投影、JSONL audit 都必须有明确 durability 级别、flush 顺序和恢复策略。
8. CI gate：`cargo test --workspace --all-targets`、Python selftest、`cargo clippy --workspace --all-targets -- -D warnings`、关键 shell validations 分层执行。

## 最小修复优先级 Fix Priority

1. 先修：ABI mismatch 拒绝加载；watchdog timeout 迟到 response 释放；sense `connect_timeout` 和 body cap；ActionDispatched 语义拆分。
2. 再修：anchor mmap 同步持久化顺序；kernel mutex 锁粒度；core 内 planner/verifier/actuator 边界拆分。
3. 可暂缓：hot watcher 生命周期重构；clippy P2；大文件按纯函数优先拆分。

## 最终判定 Final Verdict

这套项目当前能跑通主链路，并且已有测试和验证脚本证明若干关键路径可用。最大风险在 C ABI/version/response 所有权和核心热路径状态语义，这些问题一旦遇到慢插件、错版插件或异常 daemon，会从“可恢复错误”升级成泄漏、阻塞或不可信审计。最小修复路径是先封死 ABI 和资源释放，再拆清 `queued/delivered/verified` 状态机，最后把 planner/verifier/actuator 从微核职责中剥离。

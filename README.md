# 🌌 Project Genesis (创世纪)

## 📌 核心定位 (The Blueprint)
本项目采用 **微核化热插拔插件架构 (Micro-Kernelized Hot-Swappable Plugin Architecture)**。
- **终极形态**：极简宿主微核 + 动态二进制插件（.so/.dylib）。
- **核心哲学**：宿主不懂业务，插件不懂全局；一切皆契约，即插即拔，无损热更新。

---

## ⚖️ 创世纪三大物理法则 (The Iron Rules)

所有提交至本宇宙的代码，必须无条件服从以下三大法则。违背者，PR 直接驳回，物理抹杀！

### 法则一：【绝对隔离】(The Void Kernel)
- **`genesis-core` (微核大脑)** 内部**严禁**出现任何业务逻辑代码（如用户、支付、订单）。
- 微核只负责四件事：插件的加载与销毁、内存安全沙箱、事件总线路由、物理热插拔监控。

### 法则二：【契约神圣】(Contract is God)
- 插件与插件之间是一群“瞎子”，**绝对禁止**插件 A 直接引入插件 B 的二进制文件或依赖。
- 所有的跨插件调用，必须通过 `genesis-contracts` 中定义的事件结构体（Event Bus）进行异步盲发。

### 法则三：【状态湮灭】(Stateless Plugins)
- 业务插件 (`genesis-plugins` 内的产物) **严禁**在本地内存中维持持久化状态。
- 插件必须是纯粹的逻辑消化酶：吃进参数，吐出结果。状态必须下沉至外部数据库或 Redis。插件死亡、热替换期间，不得造成任何数据断层。

---

## 🏗️ 施工拓扑图 (Topology)

```text
Project_Genesis/
 ├── Cargo.toml            [造物主宪法：工作空间总控]
 ├── genesis-contracts/    [神圣契约层：全宇宙唯一的 API 真理源]
 ├── genesis-core/         [微核大脑层：事件总线与热插拔 C ABI 加载器]
 ├── genesis-cli/          [人类法杖层：剥离的 RPC 终端控制台]
 └── genesis-plugins/      [义肢仓库：所有独立编译的业务 .so 模块]

## ⚙️ 核心机制实现约束 (Engineering Constraints)

为了防止架构腐化与偏航，本宇宙的所有底层实现必须严格遵循以下物理路线，严禁私自引入重型替代方案：

1. **【动态加载机制】(FFI / C ABI)**
   - **约束**：`genesis-core` 必须使用 Rust 的 `libloading` 库来加载外部的 `.so` (Linux) 或 `.dylib` (macOS) 二进制插件。
   - **红线**：插件暴露的构造函数必须使用 `#[no_mangle] pub extern "C"` 抹除 Rust 命名粉碎，确保 C 语言级别的 ABI 二进制兼容。

2. **【事件总线机制】(Event Bus)**
   - **约束**：插件间通信必须基于纯异步的发布/订阅（Pub-Sub）模型。使用 Rust 的 `tokio` 异步运行时和 `mpsc`（多生产者单消费者）通道进行内存级消息传递。
   - **红线**：严禁在插件间传递包含内存指针的复杂对象，所有跨边界数据必须序列化为纯字符串（如 JSON）。

3. **【物理热插拔】(Hot-Swapping)**
   - **约束**：使用 `notify` 库监控 `genesis-plugins/` 目录的文件系统事件（File System Events）。
   - **红线**：在替换内存中的旧插件指针前，必须确保旧插件的“飞行中请求（In-flight requests）”处理完毕（优雅降级 Graceful Shutdown）。
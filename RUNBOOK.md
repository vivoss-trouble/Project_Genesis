# Genesis v1 Runbook

## 1. 前置环境

推荐硬件：

- Apple Silicon M 系列，建议 Max/Ultra 与大容量统一内存
- 或具备大显存的 GPU 工作站

必需工具：

- Rust / Cargo
- Python 3
- 可选：`.venv-llm` 中的 `llama-cpp-python`

若要使用真实 GGUF 模型，推荐先安装 Metal 版运行时：

```bash
python3 -m venv .venv-llm
.venv-llm/bin/python -m pip install --upgrade pip setuptools wheel cmake
CMAKE_ARGS='-DGGML_METAL=on' FORCE_CMAKE=1 \
  .venv-llm/bin/python -m pip install --no-cache-dir llama-cpp-python
```

## 2. 一键点火

`start_genesis.sh` 是 v1 复现主入口：它会构建 core、daemons 与 ABI 插件，复制 `.dylib` 到 `genesis-plugins/`，启动 arena、Brain daemon 和 `genesis-core`，并在退出时清理 socket 与子进程。

手动启动顺序仅用于排查环境问题；完整复现优先使用脚本。

Fallback 模式：

```bash
chmod +x start_genesis.sh
./start_genesis.sh
```

真实模型模式：

```bash
export GENESIS_MODEL_PATH="/Users/haypay/LocalModels/Qwen2.5-Coder-32B-Instruct-Q8_0.gguf"
export GENESIS_N_GPU_LAYERS=-1
export GENESIS_N_CTX=2048
export GENESIS_N_THREADS=8
chmod +x start_genesis.sh
./start_genesis.sh
```

脚本会启动：

1. Fantasy Dummy 靶场
2. Python LLM daemon
3. `genesis-core`

日志位置：

- Fantasy Dummy：`${GENESIS_RUNTIME_DIR:-<system temp dir>}/genesis_dummy.log`
- Web Arena：`${GENESIS_RUNTIME_DIR:-<system temp dir>}/genesis_web_arena.log`
- LLM daemon：`${GENESIS_RUNTIME_DIR:-<system temp dir>}/genesis_llm.log`
- Audit black box：`.genesis-state/audit.jsonl`

真实网页靶场模式：

```bash
export GENESIS_ARENA=web
export GENESIS_WEB_URL="https://example.com"
export GENESIS_WEB_ALLOWED_ORIGINS="https://example.com"
./start_genesis.sh
```

默认 Web Arena 只观察，不点击。允许执行点击前必须显式设置 selector allowlist：

```bash
export GENESIS_WEB_ALLOWED_SELECTORS="button.buy,#submit"
export GENESIS_ALLOWED_CLICK_TARGETS="$GENESIS_WEB_ALLOWED_SELECTORS"
```

测试闭环时可让 deterministic fallback 点击第一个双重 allowlist 命中的 selector：

```bash
export GENESIS_WEB_FALLBACK_CLICK=1
```

生产验证时保持未设置，让模型输出继续经过 purifier 与双层 allowlist。

如需真实浏览器 DOM 执行，安装 Playwright；未安装时会自动降级为只读 HTTP probe：

```bash
.venv-llm/bin/python -m pip install playwright
.venv-llm/bin/python -m playwright install chromium
```

最小 DOM 实弹例子：

```bash
export GENESIS_ARENA=web
export GENESIS_WEB_URL="https://example.com"
export GENESIS_WEB_ALLOWED_ORIGINS="https://example.com,https://www.iana.org,https://iana.org"
export GENESIS_WEB_ALLOWED_SELECTORS="a"
export GENESIS_ALLOWED_CLICK_TARGETS="a"
export GENESIS_WEB_FALLBACK_CLICK=1
./start_genesis.sh
```

## 3. 手动启动顺序

```bash
cargo build -p brain-llm -p anchor-mmap -p plugin-dummy
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

cargo run -p fantasy-dummy

GENESIS_MODEL_PATH="/absolute/path/model.gguf" \
GENESIS_N_GPU_LAYERS=-1 \
.venv-llm/bin/python genesis-daemons/llm-daemon-python/llm_daemon.py

cargo run -p genesis-core
```

## 4. 健康检查

Fantasy Dummy UI：

```text
http://127.0.0.1:4767
```

Fantasy Dummy state:

```bash
curl -s http://127.0.0.1:4767/state
```

Web Arena state:

```bash
curl -s http://127.0.0.1:4777/state
```

Web Arena self-test:

```bash
GENESIS_WEB_ARENA_SELFTEST=1 \
  python3 genesis-daemons/web-arena-python/web_arena.py
```

JSON purifier self-test:

```bash
GENESIS_DAEMON_SELFTEST=1 \
  python3 genesis-daemons/llm-daemon-python/llm_daemon.py
```

Audit event stream:

```bash
tail -f .genesis-state/audit.jsonl
```

每一行都是独立 JSON record，可用 `jq` 过滤：

```bash
jq 'select(.type == "BrainActionDecoded" or .type == "ActionDispatched")' \
  .genesis-state/audit.jsonl
```

## 5. Replay 时光机

严格只读时间轴：

```bash
cargo run -p genesis-replay -- strict --audit .genesis-state/audit.jsonl
```

影子维度核心推演：

```bash
cargo run -p genesis-replay -- simulate --audit .genesis-state/audit.jsonl
```

该模式会读取 `ReplaySnapshot`，把 Anchor 状态复制进 `.genesis-state-replay/session-*`，再把历史 `SenseCaptured` 逐帧喂给当前插件。`verdict=MATCH` 表示当前插件输出与历史 hash 一致，`DRIFT(...)` 表示逻辑漂移。

Brain 决策 mock：

```bash
cargo run -p genesis-replay -- brain-mock --audit .genesis-state/audit.jsonl
```

如需把历史动作重新发给本地靶场 actuator：

```bash
cargo run -p genesis-replay -- brain-mock --audit .genesis-state/audit.jsonl --emit-actuator
```

## 6. 故障排除

### Brain 返回 `Connection refused`

原因：LLM daemon 未启动、崩溃，或 `${GENESIS_BRAIN_SOCKET:-<system temp dir>/genesis_brain.sock}` 不存在。

处理：

```bash
rm -f "${GENESIS_BRAIN_SOCKET:-$(python3 - <<'PY'
import os, tempfile
print(os.path.join(tempfile.gettempdir(), "genesis_brain.sock"))
PY
)}"
.venv-llm/bin/python genesis-daemons/llm-daemon-python/llm_daemon.py
```

核心无需重启，下一轮 Tick 会自动重连。

### Actuator 无法执行动作

原因：Fantasy Dummy 未启动，或 `${GENESIS_ACT_SOCKET:-<system temp dir>/genesis_act.sock}` 残留。

处理：

```bash
rm -f "${GENESIS_ACT_SOCKET:-$(python3 - <<'PY'
import os, tempfile
print(os.path.join(tempfile.gettempdir(), "genesis_act.sock"))
PY
)}"
cargo run -p fantasy-dummy
```

### 插件返回 `TAINTED`

原因：插件超过 Watchdog 15ms 死线，或 worker 通道断开。

处理：检查对应插件是否在 `on_event` 中执行同步 I/O、长耗时推理、复杂正则或死循环。插件慢可以被抛弃，核心不能被拖慢。

### 模型输出非法 JSON

这是正常故障模式。Python daemon 会执行 JSON 提纯；提纯失败后进入 deterministic fallback，不会污染执行层。

### Audit 日志出现 `AuditDropped`

原因：审计队列曾经被填满，通常是磁盘 I/O 卡顿或日志洪峰。

处理：这是预期降级模式。主核心跳不会等待审计写盘；需要分析时保留现有 JSONL，并考虑降低日志粒度或扩大审计队列容量。

## 7. 停机

使用 `start_genesis.sh` 时，按 `Ctrl+C` 即可触发清理：

- 停止 Fantasy Dummy
- 停止 LLM daemon
- 删除 `${GENESIS_BRAIN_SOCKET:-<system temp dir>/genesis_brain.sock}`
- 删除 `${GENESIS_ACT_SOCKET:-<system temp dir>/genesis_act.sock}`

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
    if [[ -x ".venv-llm/bin/python" ]]; then
        PYTHON_BIN=".venv-llm/bin/python"
    else
        PYTHON_BIN="python3"
    fi
fi

GENESIS_RUNTIME_DIR="${GENESIS_RUNTIME_DIR:-$("$PYTHON_BIN" - <<'PY'
import tempfile
print(tempfile.gettempdir())
PY
)}"
export GENESIS_BRAIN_SOCKET="${GENESIS_BRAIN_SOCKET:-${GENESIS_RUNTIME_DIR}/genesis_brain.sock}"
export GENESIS_ACT_SOCKET="${GENESIS_ACT_SOCKET:-${GENESIS_RUNTIME_DIR}/genesis_act.sock}"
WEB_LOG="${GENESIS_WEB_ARENA_LOG:-${GENESIS_RUNTIME_DIR}/genesis_web_arena.log}"
DUMMY_LOG="${GENESIS_DUMMY_LOG:-${GENESIS_RUNTIME_DIR}/genesis_dummy.log}"
LLM_LOG="${GENESIS_LLM_LOG:-${GENESIS_RUNTIME_DIR}/genesis_llm.log}"

DUMMY_PID=""
WEB_PID=""
LLM_PID=""

cleanup() {
    echo "[Genesis] Shutdown requested; cleaning up..."

    if [[ -n "${DUMMY_PID}" ]] && kill -0 "${DUMMY_PID}" 2>/dev/null; then
        kill "${DUMMY_PID}" 2>/dev/null || true
    fi

    if [[ -n "${WEB_PID}" ]] && kill -0 "${WEB_PID}" 2>/dev/null; then
        kill "${WEB_PID}" 2>/dev/null || true
    fi

    if [[ -n "${LLM_PID}" ]] && kill -0 "${LLM_PID}" 2>/dev/null; then
        kill "${LLM_PID}" 2>/dev/null || true
    fi

    rm -f "$GENESIS_BRAIN_SOCKET" "$GENESIS_ACT_SOCKET"
    echo "[Genesis] System asleep."
}

trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    local max_wait="${3:-120}"

    for _ in $(seq 1 "$max_wait"); do
        if [[ -S "$socket_path" ]]; then
            echo "[Genesis] ${label} ready: ${socket_path}"
            return 0
        fi
        sleep 1
    done

    echo "[Genesis] Timed out waiting for ${label}: ${socket_path}" >&2
    return 1
}

echo "[Genesis] Ignition sequence starting..."

echo "[Genesis] Building core, daemons, and plugins..."
cargo build -p genesis-core -p fantasy-dummy -p brain-llm -p anchor-mmap -p plugin-dummy

case "$(uname -s)" in
    Darwin) PLUGIN_EXT="dylib" ;;
    Linux) PLUGIN_EXT="so" ;;
    *)
        echo "[Genesis] Unsupported host for native plugin startup: $(uname -s)" >&2
        exit 1
        ;;
esac

rm -f \
    genesis-plugins/libbrain_llm.dylib genesis-plugins/libbrain_llm.so \
    genesis-plugins/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.so \
    genesis-plugins/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.so
cp "target/debug/libbrain_llm.${PLUGIN_EXT}" "genesis-plugins/libbrain_llm.${PLUGIN_EXT}"
cp "target/debug/libanchor_mmap.${PLUGIN_EXT}" "genesis-plugins/libanchor_mmap.${PLUGIN_EXT}"
cp "target/debug/libplugin_dummy.${PLUGIN_EXT}" "genesis-plugins/libplugin_dummy.${PLUGIN_EXT}"

rm -f "$GENESIS_BRAIN_SOCKET" "$GENESIS_ACT_SOCKET"

ARENA="${GENESIS_ARENA:-fantasy}"
if [[ "$ARENA" == "web" ]]; then
    echo "[Genesis] Starting Real Web Arena..."
    export GENESIS_SENSE_URL="${GENESIS_SENSE_URL:-http://127.0.0.1:4777/state}"
    export GENESIS_SENSE_KEY="${GENESIS_SENSE_KEY:-web_state}"
    if [[ -n "${GENESIS_WEB_ALLOWED_SELECTORS:-}" && -z "${GENESIS_ALLOWED_CLICK_TARGETS:-}" ]]; then
        export GENESIS_ALLOWED_CLICK_TARGETS="$GENESIS_WEB_ALLOWED_SELECTORS"
    fi
    "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py > "$WEB_LOG" 2>&1 &
    WEB_PID=$!
    wait_for_socket "$GENESIS_ACT_SOCKET" "Web actuator airlock" 20
else
    echo "[Genesis] Starting Fantasy Dummy arena..."
    cargo run -p fantasy-dummy > "$DUMMY_LOG" 2>&1 &
    DUMMY_PID=$!
    wait_for_socket "$GENESIS_ACT_SOCKET" "Actuator airlock" 20
fi

if [[ -z "${GENESIS_MODEL_PATH:-}" ]]; then
    echo "[Genesis] GENESIS_MODEL_PATH is not set; LLM daemon will use deterministic fallback."
else
    echo "[Genesis] Loading silicon soul: ${GENESIS_MODEL_PATH}"
fi

echo "[Genesis] Starting Brain daemon with ${PYTHON_BIN}..."
"$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py > "$LLM_LOG" 2>&1 &
LLM_PID=$!
wait_for_socket "$GENESIS_BRAIN_SOCKET" "Brain airlock" 180

echo "[Genesis] Starting genesis-core in foreground..."
cargo run -p genesis-core

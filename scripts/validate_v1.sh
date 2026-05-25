#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

DUMMY_PID=""
LLM_PID=""
CORE_PID=""
WEB_PID=""
AUDIT_PATH=".genesis-state/audit.jsonl"
AUDIT_BACKUP=""

log() {
    echo "[v1-baseline] $*"
}

fail() {
    echo "[v1-baseline] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$CORE_PID" ]] && kill -0 "$CORE_PID" 2>/dev/null; then
        kill "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$DUMMY_PID" ]] && kill -0 "$DUMMY_PID" 2>/dev/null; then
        kill "$DUMMY_PID" 2>/dev/null || true
    fi
    if [[ -n "$LLM_PID" ]] && kill -0 "$LLM_PID" 2>/dev/null; then
        kill "$LLM_PID" 2>/dev/null || true
    fi
    if [[ -n "$WEB_PID" ]] && kill -0 "$WEB_PID" 2>/dev/null; then
        kill "$WEB_PID" 2>/dev/null || true
    fi

    rm -f /tmp/genesis_brain.sock /tmp/genesis_act.sock
    rm -rf .genesis-state-replay

    if [[ -n "$AUDIT_BACKUP" && -f "$AUDIT_BACKUP" ]]; then
        mv "$AUDIT_BACKUP" "$AUDIT_PATH"
    fi
}

trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    local max_wait="${3:-60}"

    for _ in $(seq 1 "$max_wait"); do
        if [[ -S "$socket_path" ]]; then
            log "$label ready: $socket_path"
            return 0
        fi
        sleep 0.2
    done

    fail "timed out waiting for $label: $socket_path"
}

log "starting Genesis v1 baseline validation"

log "checking Rust workspace"
cargo check --all-targets

log "running daemon selftests"
GENESIS_WEB_ARENA_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py

log "building core and ABI plugins"
cargo build -p genesis-core -p fantasy-dummy -p brain-llm -p anchor-mmap -p plugin-dummy
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    AUDIT_BACKUP=".genesis-state/audit.validate-backup.$(date +%s).jsonl"
    mv "$AUDIT_PATH" "$AUDIT_BACKUP"
fi

rm -f /tmp/genesis_brain.sock /tmp/genesis_act.sock

log "generating fresh fallback audit through Fantasy Dummy"
cargo run -p fantasy-dummy > /tmp/genesis_validate_dummy.log 2>&1 &
DUMMY_PID=$!
wait_for_socket /tmp/genesis_act.sock "Fantasy actuator" 100

GENESIS_LLM_LATENCY_SEC=0 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
    > /tmp/genesis_validate_llm.log 2>&1 &
LLM_PID=$!
wait_for_socket /tmp/genesis_brain.sock "Brain daemon" 100

cargo run -p genesis-core > /tmp/genesis_validate_core.log 2>&1 &
CORE_PID=$!
sleep 7
kill "$CORE_PID" 2>/dev/null || true
CORE_PID=""

[[ -f "$AUDIT_PATH" ]] || fail "fresh audit was not created"

log "checking replay strict timeline"
cargo run -p genesis-replay -- strict --audit "$AUDIT_PATH" > /tmp/genesis_validate_replay_strict.log

log "checking deterministic replay simulation"
cargo run -p genesis-replay -- simulate --audit "$AUDIT_PATH" \
    > /tmp/genesis_validate_replay_simulate.log
grep -q "drift_count=0" /tmp/genesis_validate_replay_simulate.log \
    || fail "replay drift detected; see /tmp/genesis_validate_replay_simulate.log"

log "checking brain mock replay"
cargo run -p genesis-replay -- brain-mock --audit "$AUDIT_PATH" \
    > /tmp/genesis_validate_replay_brain_mock.log

if [[ "${GENESIS_VALIDATE_LIVE_FIRE:-0}" == "1" ]]; then
    log "running optional Playwright live-fire smoke"
    kill "$DUMMY_PID" 2>/dev/null || true
    kill "$LLM_PID" 2>/dev/null || true
    DUMMY_PID=""
    LLM_PID=""
    rm -f /tmp/genesis_brain.sock /tmp/genesis_act.sock

    GENESIS_WEB_URL=https://example.com \
    GENESIS_WEB_ALLOWED_ORIGINS=https://example.com,https://www.iana.org,https://iana.org \
    GENESIS_WEB_ALLOWED_SELECTORS=a \
    GENESIS_WEB_OBSERVED_SELECTORS=a,body \
    GENESIS_WEB_ACTION_TIMEOUT_MS=5000 \
    "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py \
        > /tmp/genesis_validate_web.log 2>&1 &
    WEB_PID=$!
    wait_for_socket /tmp/genesis_act.sock "Web actuator" 100

    "$PYTHON_BIN" - <<'PY'
import json
import socket
import time
import urllib.request

def state():
    with urllib.request.urlopen("http://127.0.0.1:4777/state", timeout=3) as response:
        return json.load(response)

for _ in range(50):
    data = state()
    if data.get("mode") == "playwright" and data.get("title"):
        break
    time.sleep(0.2)
else:
    raise SystemExit("web arena did not enter playwright mode")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("/tmp/genesis_act.sock")
sock.sendall((json.dumps({
    "act": "click",
    "target": "a",
    "reason": "v1 validation live-fire",
}) + "\n").encode())
sock.close()

for _ in range(30):
    time.sleep(0.3)
    data = state()
    if "iana.org" in (data.get("url") or ""):
        break
else:
    raise SystemExit(f"live-fire navigation failed: {data}")
PY
fi

log "Genesis v1 baseline validation passed"

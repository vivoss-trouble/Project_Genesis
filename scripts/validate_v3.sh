#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_validate_v3.XXXXXX)"
ORIGINAL_AUDIT=""
DUMMY_PID=""
WEB_PID=""
LLM_PID=""
CORE_PID=""

HAPPY_AUDIT="/tmp/genesis_v3_happy_audit.jsonl"
HAPPY_REPLAY="/tmp/genesis_v3_happy_replay.log"
HAPPY_DB="/tmp/genesis_v3_happy.sqlite"
ABORT_AUDIT="/tmp/genesis_v3_abort_audit.jsonl"
ABORT_REPLAY="/tmp/genesis_v3_abort_replay.log"
ABORT_DB="/tmp/genesis_v3_abort.sqlite"

log() {
    echo "[v3-baseline] $*"
}

fail() {
    echo "[v3-baseline] ERROR: $*" >&2
    exit 1
}

stop_processes() {
    if [[ -n "$CORE_PID" ]] && kill -0 "$CORE_PID" 2>/dev/null; then
        kill "$CORE_PID" 2>/dev/null || true
        wait "$CORE_PID" 2>/dev/null || true
    fi
    if [[ -n "$DUMMY_PID" ]] && kill -0 "$DUMMY_PID" 2>/dev/null; then
        kill "$DUMMY_PID" 2>/dev/null || true
        wait "$DUMMY_PID" 2>/dev/null || true
    fi
    if [[ -n "$WEB_PID" ]] && kill -0 "$WEB_PID" 2>/dev/null; then
        kill "$WEB_PID" 2>/dev/null || true
        wait "$WEB_PID" 2>/dev/null || true
    fi
    if [[ -n "$LLM_PID" ]] && kill -0 "$LLM_PID" 2>/dev/null; then
        kill "$LLM_PID" 2>/dev/null || true
        wait "$LLM_PID" 2>/dev/null || true
    fi
    CORE_PID=""
    DUMMY_PID=""
    WEB_PID=""
    LLM_PID=""
    rm -f /tmp/genesis_brain.sock /tmp/genesis_act.sock
}

cleanup() {
    stop_processes
    rm -rf .genesis-state-replay "$TMP_DIR"
    if [[ -n "$ORIGINAL_AUDIT" && -f "$ORIGINAL_AUDIT" ]]; then
        mv "$ORIGINAL_AUDIT" "$AUDIT_PATH"
    else
        rm -f "$AUDIT_PATH"
    fi
}

trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    for _ in $(seq 1 100); do
        if [[ -S "$socket_path" ]]; then
            log "$label ready: $socket_path"
            return 0
        fi
        sleep 0.2
    done
    fail "timed out waiting for $label: $socket_path"
}

fresh_audit() {
    stop_processes
    rm -f "$AUDIT_PATH"
}

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "running inherited v1 redline"
./scripts/validate_v1.sh
rm -f "$AUDIT_PATH"

log "building v3 execution artifacts"
cargo build -p genesis-core -p fantasy-dummy -p brain-llm -p anchor-mmap -p plugin-dummy
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "running Fantasy JIT success path"
fresh_audit
cargo run -p fantasy-dummy > /tmp/genesis_v3_happy_dummy.log 2>&1 &
DUMMY_PID=$!
wait_for_socket /tmp/genesis_act.sock "Fantasy actuator"
sleep "${GENESIS_VALIDATE_V3_HEALTH_DECAY_SEC:-8}"

GENESIS_LLM_LATENCY_SEC=0 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
    > /tmp/genesis_v3_happy_llm.log 2>&1 &
LLM_PID=$!
wait_for_socket /tmp/genesis_brain.sock "Brain daemon"

GENESIS_MACRO_GOAL="Handle a drifting healing target under falling health: observe health, compile only allowlisted heal actions just in time, avoid repeating failed actions, and verify recovery through the v2 loop" \
    cargo run -p genesis-core > /tmp/genesis_v3_happy_core.log 2>&1 &
CORE_PID=$!
sleep "${GENESIS_VALIDATE_V3_HAPPY_SEC:-18}"
stop_processes

[[ -f "$AUDIT_PATH" ]] || fail "Fantasy success audit was not created"
cp "$AUDIT_PATH" "$HAPPY_AUDIT"
cargo run -p genesis-replay -- strict --audit "$HAPPY_AUDIT" > "$HAPPY_REPLAY"
"$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$HAPPY_AUDIT" --db "$HAPPY_DB"
"$PYTHON_BIN" - "$HAPPY_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
events = conn.execute(
    "SELECT event_type, from_step, to_step FROM plan_events ORDER BY rowid"
).fetchall()
actions = conn.execute(
    """
    SELECT a.act, a.target, o.status
    FROM actions AS a
    LEFT JOIN outcomes AS o USING (action_id)
    """
).fetchall()
assert any(row[0] == "PlanAdvanced" for row in events), events
assert ("click", "#heal-btn", "Verified") in actions, actions
PY
log "Fantasy path verified: allowlisted JIT heal advanced the cursor"

log "running forced read-only fail-fast path"
fresh_audit
GENESIS_WEB_FORCE_READ_ONLY=1 \
GENESIS_WEB_URL=https://example.com \
GENESIS_WEB_ALLOWED_ORIGINS=https://example.com \
GENESIS_WEB_ALLOWED_SELECTORS=a \
GENESIS_WEB_OBSERVED_SELECTORS=a,body \
    "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py \
    > /tmp/genesis_v3_abort_web.log 2>&1 &
WEB_PID=$!
wait_for_socket /tmp/genesis_act.sock "Web actuator"

GENESIS_ALLOWED_CLICK_TARGETS=a \
GENESIS_WEB_FALLBACK_CLICK=1 \
GENESIS_LLM_LATENCY_SEC=0 \
    "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
    > /tmp/genesis_v3_abort_llm.log 2>&1 &
LLM_PID=$!
wait_for_socket /tmp/genesis_brain.sock "Brain daemon"

GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
GENESIS_SENSE_KEY=web_state \
GENESIS_MACRO_GOAL="Navigate only if the link selector is safe, observe errors, and abort plan if the read-only arena rejects the click" \
    cargo run -p genesis-core > /tmp/genesis_v3_abort_core.log 2>&1 &
CORE_PID=$!
sleep "${GENESIS_VALIDATE_V3_ABORT_SEC:-22}"
stop_processes

[[ -f "$AUDIT_PATH" ]] || fail "Web abort audit was not created"
cp "$AUDIT_PATH" "$ABORT_AUDIT"
cargo run -p genesis-replay -- strict --audit "$ABORT_AUDIT" > "$ABORT_REPLAY"
"$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$ABORT_AUDIT" --db "$ABORT_DB"
"$PYTHON_BIN" - "$ABORT_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
abort = conn.execute(
    "SELECT reason FROM plan_events WHERE event_type = 'PlanAborted' LIMIT 1"
).fetchone()
failed = conn.execute(
    """
    SELECT a.act, a.target, o.status, o.failure_kind
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click' AND a.target = 'a'
    LIMIT 1
    """
).fetchone()
plans = conn.execute("SELECT COUNT(*) FROM plans").fetchone()[0]
assert abort and "ReadOnlyMode" in abort[0], abort
assert failed == ("click", "a", "Failed", "ReadOnlyMode"), failed
assert plans >= 2, plans
PY
log "Web path verified: bound ReadOnlyMode outcome aborted the cursor and replanned"
log "Genesis v3.2 baseline validation passed"

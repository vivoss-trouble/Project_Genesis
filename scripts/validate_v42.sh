#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_validate_v42.XXXXXX)"
ORIGINAL_AUDIT=""
DYNAMIC_PID=""
LLM_PID=""
CORE_PID=""

log() {
    echo "[v4.2-baseline] $*"
}

fail() {
    echo "[v4.2-baseline] ERROR: $*" >&2
    exit 1
}

stop_run() {
    for pid_var in CORE_PID LLM_PID DYNAMIC_PID; do
        pid="${!pid_var}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        printf -v "$pid_var" '%s' ""
    done
    rm -f /tmp/genesis_brain.sock /tmp/genesis_dynamic_act.sock
}

cleanup() {
    stop_run
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
            return
        fi
        sleep 0.1
    done
    fail "timed out waiting for $label"
}

wait_for_state() {
    for _ in $(seq 1 100); do
        if "$PYTHON_BIN" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4781/state", timeout=0.2).read()' \
            >/dev/null 2>&1; then
            log "dynamic state endpoint ready"
            return
        fi
        sleep 0.1
    done
    fail "timed out waiting for dynamic state endpoint"
}

run_dynamic_case() {
    local label="$1"
    local fallback_mode="$2"
    local tolerance="$3"
    local expected_status="$4"
    local expected_failure="$5"
    local audit="$TMP_DIR/${label}.audit.jsonl"
    local db="$TMP_DIR/${label}.sqlite"

    stop_run
    rm -f "$AUDIT_PATH"

    GENESIS_DYNAMIC_SELFTEST_MODE=1 \
    GENESIS_DYNAMIC_FPS=60 \
    GENESIS_DYNAMIC_FRESH_FRAME_TOLERANCE="$tolerance" \
        "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py \
        > "/tmp/genesis_v42_${label}_arena.log" 2>&1 &
    DYNAMIC_PID=$!
    wait_for_socket /tmp/genesis_dynamic_act.sock "Dynamic actuator"
    wait_for_state

    GENESIS_MODEL_PATH="" \
    GENESIS_ALLOWED_CLICK_TARGETS=heal \
    GENESIS_ALLOWED_WAIT_SELECTORS=heal \
    GENESIS_DYNAMIC_FALLBACK_MODE="$fallback_mode" \
    GENESIS_LLM_LATENCY_SEC=0 \
        "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
        > "/tmp/genesis_v42_${label}_llm.log" 2>&1 &
    LLM_PID=$!
    wait_for_socket /tmp/genesis_brain.sock "Brain daemon"

    GENESIS_SENSE_URL=http://127.0.0.1:4781/state \
    GENESIS_SENSE_KEY=dynamic_state \
    GENESIS_MACRO_GOAL="Use the latest dynamic frame to compile a safe click_point for target heal and classify the arena verdict" \
        cargo run -p genesis-core > "/tmp/genesis_v42_${label}_core.log" 2>&1 &
    CORE_PID=$!
    sleep "${GENESIS_VALIDATE_V42_CASE_SEC:-18}"
    stop_run

    [[ -f "$AUDIT_PATH" ]] || fail "$label audit was not created"
    cp "$AUDIT_PATH" "$audit"
    cargo run -p genesis-replay -- strict --audit "$audit" \
        > "/tmp/genesis_v42_${label}_replay.log"
    "$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$audit" --db "$db"
    "$PYTHON_BIN" - "$db" "$expected_status" "$expected_failure" <<'PY'
import json
import sqlite3
import sys

db, expected_status, expected_failure = sys.argv[1:]
conn = sqlite3.connect(db)
row = conn.execute(
    """
    SELECT a.action_id, o.status, COALESCE(o.failure_kind, ''), o.evidence_json
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click_point'
    ORDER BY o.timestamp_ms
    LIMIT 1
    """
).fetchone()
assert row is not None, "missing click_point outcome"
action_id, status, failure_kind, evidence_json = row
evidence = json.loads(evidence_json)
assert status == expected_status, row
assert failure_kind == expected_failure, row
assert evidence.get("expected_action_id") == action_id, evidence
assert evidence.get("verdict_action_id") == action_id, evidence
assert evidence.get("last_verdict", {}).get("action_id") == action_id, evidence
if expected_status == "Verified":
    advanced = conn.execute(
        "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAdvanced'"
    ).fetchone()[0]
    assert advanced >= 1, advanced
else:
    aborted = conn.execute(
        "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAborted'"
    ).fetchone()[0]
    assert aborted >= 1, aborted
conn.close()
PY
}

if [[ "${GENESIS_VALIDATE_V42_SKIP_INHERITED:-0}" != "1" ]]; then
    log "running inherited v3.4 redline"
    ./scripts/validate_v34.sh
fi

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "running static, purifier, and arena checks"
cargo test -p genesis-core
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py
GENESIS_DYNAMIC_ARENA_SELFTEST=1 GENESIS_DYNAMIC_SELFTEST_MODE=1 \
    "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py
"$PYTHON_BIN" scripts/project_audit_sqlite.py --selftest
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "verifying dynamic click_point happy path"
run_dynamic_case hit hit 10000 Verified ""

log "verifying stale-frame failure taxonomy"
run_dynamic_case stale stale 2 Failed StaleFrame

log "verifying coordinate-out-of-bounds failure taxonomy"
run_dynamic_case oob oob 10000 Failed CoordinateOutOfBounds

log "verifying target-drift failure taxonomy"
run_dynamic_case drift drift 10000 Failed TargetDrift

log "Genesis v4.2 dynamic click_point validation passed"

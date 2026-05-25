#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_validate_v43.XXXXXX)"
ORIGINAL_AUDIT=""
DYNAMIC_PID=""
LLM_PID=""
CORE_PID=""
ADVISORY_DB="$TMP_DIR/dynamic-advisory.sqlite"

log() {
    echo "[v4.3-baseline] $*"
}

fail() {
    echo "[v4.3-baseline] ERROR: $*" >&2
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

run_case() {
    local label="$1"
    local memory_mode="$2"
    local audit="$TMP_DIR/${label}.audit.jsonl"
    local db="$TMP_DIR/${label}.sqlite"

    stop_run
    rm -f "$AUDIT_PATH"

    GENESIS_DYNAMIC_SELFTEST_MODE=1 \
    GENESIS_DYNAMIC_FPS=60 \
    GENESIS_DYNAMIC_FRESH_FRAME_TOLERANCE=10000 \
        "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py \
        > "/tmp/genesis_v43_${label}_arena.log" 2>&1 &
    DYNAMIC_PID=$!
    wait_for_socket /tmp/genesis_dynamic_act.sock "Dynamic actuator ($label)"
    wait_for_state

    if [[ "$memory_mode" == "with-advisory" ]]; then
        GENESIS_TEST_DYNAMIC_ADVISORY_MODEL=1 \
        GENESIS_ALLOWED_CLICK_TARGETS=heal \
        GENESIS_ALLOWED_WAIT_SELECTORS=heal \
        GENESIS_ADVISORY_DB="$ADVISORY_DB" \
        GENESIS_ADVISORY_SAMPLE_LIMIT=25 \
        GENESIS_ADVISORY_QUERY_MS=50 \
        GENESIS_LLM_LATENCY_SEC=0 \
            "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
            > "/tmp/genesis_v43_${label}_llm.log" 2>&1 &
    else
        GENESIS_TEST_DYNAMIC_ADVISORY_MODEL=1 \
        GENESIS_DYNAMIC_ADVISORY_CONTROL_ACTION=click_point \
        GENESIS_DYNAMIC_FALLBACK_ACTION=click_point \
        GENESIS_DYNAMIC_FALLBACK_MODE=drift \
        GENESIS_ALLOWED_CLICK_TARGETS=heal \
        GENESIS_ALLOWED_WAIT_SELECTORS=heal \
        GENESIS_LLM_LATENCY_SEC=0 \
            "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
            > "/tmp/genesis_v43_${label}_llm.log" 2>&1 &
    fi
    LLM_PID=$!
    wait_for_socket /tmp/genesis_brain.sock "Brain daemon ($label)"

    GENESIS_SENSE_URL=http://127.0.0.1:4781/state \
    GENESIS_SENSE_KEY=dynamic_state \
    GENESIS_MACRO_GOAL="Use bounded dynamic history only as advice while compiling target heal in the current frame" \
        cargo run -p genesis-core > "/tmp/genesis_v43_${label}_core.log" 2>&1 &
    CORE_PID=$!
    sleep "${GENESIS_VALIDATE_V43_CASE_SEC:-18}"
    stop_run

    [[ -f "$AUDIT_PATH" ]] || fail "$label audit was not created"
    cp "$AUDIT_PATH" "$audit"
    cargo run -p genesis-replay -- strict --audit "$audit" \
        > "$TMP_DIR/${label}.replay.log"
    "$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$audit" --db "$db"

    if [[ "$memory_mode" == "without-advisory" ]]; then
        "$PYTHON_BIN" - "$db" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
drift = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click_point'
      AND a.target = 'heal'
      AND o.status = 'Failed'
      AND o.failure_kind = 'TargetDrift'
    """
).fetchone()[0]
advisories = conn.execute("SELECT COUNT(*) FROM memory_advisories").fetchone()[0]
aborted = conn.execute(
    "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAborted'"
).fetchone()[0]
conn.close()
assert drift >= 1, drift
assert advisories == 0, advisories
assert aborted >= 1, aborted
PY
        log "control verdict: no advisory -> risky click_point -> TargetDrift -> PlanAborted"
    else
        "$PYTHON_BIN" - "$db" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
advisory = conn.execute(
    """
    SELECT scope, sample_count
    FROM memory_advisories
    ORDER BY timestamp_ms
    LIMIT 1
    """
).fetchone()
verified_noop = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'noop' AND o.status = 'Verified'
    """
).fetchone()[0]
failed_click_points = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click_point' AND o.status = 'Failed'
    """
).fetchone()[0]
advanced = conn.execute(
    "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAdvanced'"
).fetchone()[0]
conn.close()
assert advisory == ("active_step_target", 4), advisory
assert verified_noop >= 1, verified_noop
assert failed_click_points == 0, failed_click_points
assert advanced >= 1, advanced
PY
        log "advisory verdict: TargetDrift/StaleFrame history -> noop -> Verified -> PlanAdvanced"
    fi
}

if [[ "${GENESIS_VALIDATE_V43_SKIP_INHERITED:-0}" != "1" ]]; then
    log "running inherited v4.2 redline"
    ./scripts/validate_v42.sh
fi

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "building action path and checking controlled dynamic advisory model"
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "seeding repeated dynamic drift/stale outcomes for target=heal"
"$PYTHON_BIN" - "$ADVISORY_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.executescript(
    """
    CREATE TABLE actions (
        action_id TEXT PRIMARY KEY,
        act TEXT,
        target TEXT,
        action_json TEXT NOT NULL
    );
    CREATE TABLE outcomes (
        action_id TEXT PRIMARY KEY,
        timestamp_ms INTEGER NOT NULL,
        status TEXT NOT NULL,
        failure_kind TEXT,
        warning_kind TEXT
    );
    INSERT INTO actions VALUES
        ('dyn-1', 'click_point', 'heal', '{}'),
        ('dyn-2', 'click_point', 'heal', '{}'),
        ('dyn-3', 'click_point', 'heal', '{}'),
        ('dyn-4', 'click_point', 'heal', '{}');
    INSERT INTO outcomes VALUES
        ('dyn-1', 1, 'Failed', 'TargetDrift', NULL),
        ('dyn-2', 2, 'Failed', 'TargetDrift', NULL),
        ('dyn-3', 3, 'Failed', 'StaleFrame', NULL),
        ('dyn-4', 4, 'Verified', NULL, 'StaleButHit');
    """
)
conn.commit()
conn.close()
PY

log "running control universe without dynamic advisory"
run_case control without-advisory

log "running advisory universe with the same current dynamic state"
run_case advised with-advisory

log "Genesis v4.3 dynamic advisory validation passed"

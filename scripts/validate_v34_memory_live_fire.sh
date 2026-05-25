#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_memory_live_fire.XXXXXX)"
ORIGINAL_AUDIT=""
FIXTURE_PID=""
WEB_PID=""
LLM_PID=""
CORE_PID=""
ADVISORY_DB="$TMP_DIR/rejection-history.sqlite"

log() {
    echo "[memory-live-fire] $*"
}

fail() {
    echo "[memory-live-fire] ERROR: $*" >&2
    exit 1
}

stop_run() {
    for pid_var in CORE_PID WEB_PID LLM_PID; do
        pid="${!pid_var}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
        printf -v "$pid_var" '%s' ""
    done
    rm -f /tmp/genesis_brain.sock /tmp/genesis_act.sock
}

cleanup() {
    stop_run
    if [[ -n "$FIXTURE_PID" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
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
        sleep 0.2
    done
    fail "timed out waiting for $label"
}

wait_for_fixture() {
    for _ in $(seq 1 50); do
        if "$PYTHON_BIN" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4790/", timeout=0.2).read()' \
            >/dev/null 2>&1; then
            log "trap fixture ready: http://127.0.0.1:4790/"
            return
        fi
        sleep 0.2
    done
    fail "timed out waiting for trap fixture"
}

run_case() {
    local label="$1"
    local memory_mode="$2"
    local audit="$TMP_DIR/${label}.jsonl"
    local db="$TMP_DIR/${label}.sqlite"
    stop_run
    rm -f "$AUDIT_PATH"

    GENESIS_WEB_FORCE_READ_ONLY=1 \
    GENESIS_WEB_URL=http://127.0.0.1:4790/ \
    GENESIS_WEB_ALLOWED_ORIGINS=http://127.0.0.1:4790 \
    GENESIS_WEB_ALLOWED_SELECTORS=a \
    GENESIS_WEB_OBSERVED_SELECTORS=a,body \
        "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py \
        > "/tmp/genesis_memory_${label}_web.log" 2>&1 &
    WEB_PID=$!
    wait_for_socket /tmp/genesis_act.sock "Web actuator ($label)"

    if [[ "$memory_mode" == "with-advisory" ]]; then
        GENESIS_TEST_MEMORY_GUIDED_MODEL=1 \
        GENESIS_ALLOWED_CLICK_TARGETS=a \
        GENESIS_ALLOWED_WAIT_SELECTORS=a \
        GENESIS_ADVISORY_DB="$ADVISORY_DB" \
        GENESIS_ADVISORY_SAMPLE_LIMIT=25 \
        GENESIS_ADVISORY_QUERY_MS=50 \
        GENESIS_LLM_LATENCY_SEC=0 \
            "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
            > "/tmp/genesis_memory_${label}_llm.log" 2>&1 &
    else
        GENESIS_TEST_MEMORY_GUIDED_MODEL=1 \
        GENESIS_ALLOWED_CLICK_TARGETS=a \
        GENESIS_ALLOWED_WAIT_SELECTORS=a \
        GENESIS_LLM_LATENCY_SEC=0 \
            "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
            > "/tmp/genesis_memory_${label}_llm.log" 2>&1 &
    fi
    LLM_PID=$!
    wait_for_socket /tmp/genesis_brain.sock "Brain daemon ($label)"

    GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
    GENESIS_SENSE_KEY=web_state \
    GENESIS_MACRO_GOAL="Resolve the allowlisted target while avoiding historically rejected tactics" \
        cargo run -p genesis-core > "/tmp/genesis_memory_${label}_core.log" 2>&1 &
    CORE_PID=$!
    # Leave enough post-verdict ticks for the intentionally buffered audit
    # writer to emit records without forcing a synchronous flush in the core.
    sleep "${GENESIS_MEMORY_LIVE_FIRE_CASE_SEC:-26}"
    stop_run

    [[ -f "$AUDIT_PATH" ]] || fail "$label audit was not created"
    cp "$AUDIT_PATH" "$audit"
    cargo run -p genesis-replay -- strict --audit "$audit" > "$TMP_DIR/${label}.replay.log"
    "$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$audit" --db "$db"

    if [[ "$memory_mode" == "without-advisory" ]]; then
        "$PYTHON_BIN" - "$db" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
click_failure = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click' AND a.target = 'a'
      AND o.status = 'Failed' AND o.failure_kind = 'ReadOnlyMode'
    """
).fetchone()[0]
aborted = conn.execute(
    "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAborted'"
).fetchone()[0]
advisories = conn.execute("SELECT COUNT(*) FROM memory_advisories").fetchone()[0]
conn.close()
assert click_failure >= 1, click_failure
assert aborted >= 1, aborted
assert advisories == 0, advisories
PY
        log "control verdict: no advisory -> click -> ReadOnlyMode -> PlanAborted"
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
verified_wait = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'wait' AND o.status = 'Verified'
    """
).fetchone()[0]
failed_clicks = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'click' AND o.status = 'Failed'
    """
).fetchone()[0]
advanced = conn.execute(
    "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAdvanced'"
).fetchone()[0]
conn.close()
assert advisory == ("active_step_target", 4), advisory
assert verified_wait >= 1, verified_wait
assert failed_clicks == 0, failed_clicks
assert advanced >= 1, advanced
PY
        log "advisory verdict: repeated ReadOnlyMode -> wait -> Verified -> PlanAdvanced"
    fi
}

if [[ "${GENESIS_MEMORY_LIVE_FIRE_SKIP_BASELINE:-0}" != "1" ]]; then
    log "running v3.4 baseline before causal experiment"
    ./scripts/validate_v34.sh
fi

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "building action path and checking controlled Brain model"
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "seeding four repeated ReadOnlyMode outcomes for target=a"
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
        failure_kind TEXT
    );
    INSERT INTO actions VALUES
        ('trap-1', 'click', 'a', '{}'),
        ('trap-2', 'click', 'a', '{}'),
        ('trap-3', 'click', 'a', '{}'),
        ('trap-4', 'click', 'a', '{}');
    INSERT INTO outcomes VALUES
        ('trap-1', 1, 'Failed', 'ReadOnlyMode'),
        ('trap-2', 2, 'Failed', 'ReadOnlyMode'),
        ('trap-3', 3, 'Failed', 'ReadOnlyMode'),
        ('trap-4', 4, 'Failed', 'ReadOnlyMode');
    """
)
conn.commit()
conn.close()
PY

"$PYTHON_BIN" -c 'from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b"<html><head><title>Memory Trap</title></head><body><a>Observed Safe Target</a></body></html>"
        self.send_response(200); self.send_header("Content-Type","text/html"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
ThreadingHTTPServer(("127.0.0.1",4790),H).serve_forever()' \
    > /tmp/genesis_memory_fixture.log 2>&1 &
FIXTURE_PID=$!
wait_for_fixture

log "running control universe without historical advisory"
run_case control without-advisory

log "running advisory universe with the same present DOM state"
run_case advised with-advisory

log "Memory-guided live-fire A/B validation passed"

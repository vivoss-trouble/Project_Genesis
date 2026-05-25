#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_validate_v34.XXXXXX)"
ORIGINAL_AUDIT=""
FIXTURE_PID=""
WEB_PID=""
LLM_PID=""
CORE_PID=""
ADVISORY_DB="$TMP_DIR/advisory-source.sqlite"
RESULT_DB="$TMP_DIR/advisory-observed.sqlite"
RESULT_AUDIT="$TMP_DIR/advisory-audit.jsonl"
RESULT_REPLAY="$TMP_DIR/advisory-replay.log"

log() {
    echo "[v3.4-baseline] $*"
}

fail() {
    echo "[v3.4-baseline] ERROR: $*" >&2
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
        if "$PYTHON_BIN" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4789/", timeout=0.2).read()' \
            >/dev/null 2>&1; then
            log "local DOM fixture ready: http://127.0.0.1:4789/"
            return
        fi
        sleep 0.2
    done
    fail "timed out waiting for local DOM fixture"
}

if [[ "${GENESIS_VALIDATE_V34_SKIP_INHERITED:-0}" != "1" ]]; then
    log "running inherited v3.3 redline"
    ./scripts/validate_v33.sh
fi

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "running static checks and building execution artifacts"
cargo test -p genesis-core
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py
"$PYTHON_BIN" scripts/project_audit_sqlite.py --selftest
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "seeding bounded historical advisory projection"
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
        ('history-1', 'wait', NULL, '{"expected_state":{"selector":"a"}}'),
        ('history-2', 'click', 'a', '{}'),
        ('history-3', 'wait', NULL, '{"expected_state":{"selector":"a"}}');
    INSERT INTO outcomes VALUES
        ('history-1', 1, 'Failed', 'WaitConditionNotMet'),
        ('history-2', 2, 'Failed', 'ReadOnlyMode'),
        ('history-3', 3, 'Verified', NULL);
    """
)
conn.commit()
conn.close()
PY

log "starting deterministic local DOM fixture"
"$PYTHON_BIN" -c 'from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b"<html><head><title>Advisory Fixture</title></head><body><a>Ready</a></body></html>"
        self.send_response(200); self.send_header("Content-Type","text/html"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
ThreadingHTTPServer(("127.0.0.1",4789),H).serve_forever()' \
    > /tmp/genesis_v34_fixture.log 2>&1 &
FIXTURE_PID=$!
wait_for_fixture

GENESIS_WEB_FORCE_READ_ONLY=1 \
GENESIS_WEB_URL=http://127.0.0.1:4789/ \
GENESIS_WEB_ALLOWED_ORIGINS=http://127.0.0.1:4789 \
GENESIS_WEB_ALLOWED_SELECTORS=a \
GENESIS_WEB_OBSERVED_SELECTORS=a,body \
    "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py \
    > /tmp/genesis_v34_web.log 2>&1 &
WEB_PID=$!
wait_for_socket /tmp/genesis_act.sock "Web actuator"

GENESIS_ALLOWED_CLICK_TARGETS=a \
GENESIS_ALLOWED_WAIT_SELECTORS=a \
GENESIS_WEB_FALLBACK_WAIT_SELECTOR=a \
GENESIS_WEB_FALLBACK_WAIT_MS=1000 \
GENESIS_ADVISORY_DB="$ADVISORY_DB" \
GENESIS_ADVISORY_SAMPLE_LIMIT=25 \
GENESIS_ADVISORY_QUERY_MS=50 \
GENESIS_LLM_LATENCY_SEC=0 \
    "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
    > /tmp/genesis_v34_llm.log 2>&1 &
LLM_PID=$!
wait_for_socket /tmp/genesis_brain.sock "Brain daemon"

GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
GENESIS_SENSE_KEY=web_state \
GENESIS_MACRO_GOAL="Use present DOM state and bounded historical advice to wait only for allowlisted visible controls" \
    cargo run -p genesis-core > /tmp/genesis_v34_core.log 2>&1 &
CORE_PID=$!
sleep "${GENESIS_VALIDATE_V34_CASE_SEC:-20}"
stop_run

[[ -f "$AUDIT_PATH" ]] || fail "advisory audit was not created"
cp "$AUDIT_PATH" "$RESULT_AUDIT"
cargo run -p genesis-replay -- strict --audit "$RESULT_AUDIT" > "$RESULT_REPLAY"
grep -q "memory advisory scope=active_step_target samples=3" "$RESULT_REPLAY" \
    || fail "replay did not expose bounded advisory metadata"
"$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$RESULT_AUDIT" --db "$RESULT_DB"
"$PYTHON_BIN" - "$RESULT_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
advisory = conn.execute(
    """
    SELECT scope, sample_count, length(advisory_hash)
    FROM memory_advisories
    ORDER BY timestamp_ms
    LIMIT 1
    """
).fetchone()
actions_with_wrapper = conn.execute(
    "SELECT COUNT(*) FROM actions WHERE action_json LIKE '%advisory_meta%'"
).fetchone()[0]
verified_wait = conn.execute(
    """
    SELECT COUNT(*)
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'wait' AND o.status = 'Verified'
    """
).fetchone()[0]
conn.close()
assert advisory == ("active_step_target", 3, 16), advisory
assert actions_with_wrapper == 0, actions_with_wrapper
assert verified_wait >= 1, verified_wait
PY

log "Genesis v3.4 read model advisory validation passed"

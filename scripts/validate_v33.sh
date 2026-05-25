#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_validate_v33.XXXXXX)"
ORIGINAL_AUDIT=""
FIXTURE_PID=""
WEB_PID=""
LLM_PID=""
CORE_PID=""

log() {
    echo "[v3.3-baseline] $*"
}

fail() {
    echo "[v3.3-baseline] ERROR: $*" >&2
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
        if "$PYTHON_BIN" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4788/", timeout=0.2).read()' \
            >/dev/null 2>&1; then
            log "local DOM fixture ready: http://127.0.0.1:4788/"
            return
        fi
        sleep 0.2
    done
    fail "timed out waiting for local DOM fixture"
}

run_wait_case() {
    local label="$1"
    local selector="$2"
    local expected_status="$3"
    local expected_failure="$4"
    local audit="/tmp/genesis_v33_${label}_audit.jsonl"
    local db="/tmp/genesis_v33_${label}.sqlite"

    stop_run
    rm -f "$AUDIT_PATH"

    GENESIS_WEB_FORCE_READ_ONLY=1 \
    GENESIS_WEB_URL=http://127.0.0.1:4788/ \
    GENESIS_WEB_ALLOWED_ORIGINS=http://127.0.0.1:4788 \
    GENESIS_WEB_ALLOWED_SELECTORS="$selector" \
    GENESIS_WEB_OBSERVED_SELECTORS=a,button,body \
        "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py \
        > "/tmp/genesis_v33_${label}_web.log" 2>&1 &
    WEB_PID=$!
    wait_for_socket /tmp/genesis_act.sock "Web actuator"

    GENESIS_ALLOWED_CLICK_TARGETS="$selector" \
    GENESIS_ALLOWED_WAIT_SELECTORS="$selector" \
    GENESIS_WEB_FALLBACK_WAIT_SELECTOR="$selector" \
    GENESIS_WEB_FALLBACK_WAIT_MS=1000 \
    GENESIS_LLM_LATENCY_SEC=0 \
        "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
        > "/tmp/genesis_v33_${label}_llm.log" 2>&1 &
    LLM_PID=$!
    wait_for_socket /tmp/genesis_brain.sock "Brain daemon"

    GENESIS_SENSE_URL=http://127.0.0.1:4777/state \
    GENESIS_SENSE_KEY=web_state \
    GENESIS_MACRO_GOAL="Wait for the allowlisted selector to become visible before any physical action" \
        cargo run -p genesis-core > "/tmp/genesis_v33_${label}_core.log" 2>&1 &
    CORE_PID=$!
    sleep "${GENESIS_VALIDATE_V33_CASE_SEC:-20}"
    stop_run

    [[ -f "$AUDIT_PATH" ]] || fail "$label audit was not created"
    cp "$AUDIT_PATH" "$audit"
    cargo run -p genesis-replay -- strict --audit "$audit" \
        > "/tmp/genesis_v33_${label}_replay.log"
    "$PYTHON_BIN" scripts/project_audit_sqlite.py --rebuild --audit "$audit" --db "$db"
    "$PYTHON_BIN" - "$db" "$selector" "$expected_status" "$expected_failure" <<'PY'
import sqlite3
import sys

db, selector, expected_status, expected_failure = sys.argv[1:]
conn = sqlite3.connect(db)
wait = conn.execute(
    """
    SELECT o.status, COALESCE(o.failure_kind, '')
    FROM actions AS a
    JOIN outcomes AS o USING (action_id)
    WHERE a.act = 'wait'
      AND json_extract(a.action_json, '$.expected_state.selector') = ?
    LIMIT 1
    """,
    (selector,),
).fetchone()
assert wait is not None, selector
assert wait[0] == expected_status, wait
assert wait[1] == expected_failure, wait
if expected_status == "Failed":
    aborted = conn.execute(
        "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAborted'"
    ).fetchone()[0]
    assert aborted >= 1, aborted
else:
    advanced = conn.execute(
        "SELECT COUNT(*) FROM plan_events WHERE event_type = 'PlanAdvanced'"
    ).fetchone()[0]
    assert advanced >= 1, advanced
PY
}

if [[ "${GENESIS_VALIDATE_V33_SKIP_INHERITED:-0}" != "1" ]]; then
    log "running inherited v3.2 redline"
    ./scripts/validate_v3.sh
fi

mkdir -p .genesis-state
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "running static and purifier checks"
cargo test -p genesis-core
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
GENESIS_DAEMON_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py
GENESIS_WEB_ARENA_SELFTEST=1 "$PYTHON_BIN" genesis-daemons/web-arena-python/web_arena.py
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "starting deterministic local DOM fixture"
"$PYTHON_BIN" -c 'from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b"<html><head><title>Wait Fixture</title></head><body><a>Ready</a></body></html>"
        self.send_response(200); self.send_header("Content-Type","text/html"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
ThreadingHTTPServer(("127.0.0.1",4788),H).serve_forever()' \
    > /tmp/genesis_v33_fixture.log 2>&1 &
FIXTURE_PID=$!
wait_for_fixture

log "verifying visible-element wait advances the cursor"
run_wait_case visible a Verified ""

log "verifying missing-element wait aborts the cursor"
run_wait_case missing button Failed WaitConditionNotMet

log "Genesis v3.3 verifiable backoff validation passed"

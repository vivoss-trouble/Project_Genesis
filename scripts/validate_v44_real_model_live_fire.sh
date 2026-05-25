#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
if [[ -x ".venv-llm/bin/python" ]]; then
    PYTHON_BIN="${GENESIS_PYTHON:-.venv-llm/bin/python}"
fi

LIVE_FIRE_SEC="${GENESIS_LIVE_FIRE_SEC:-45}"
RUN_ID="${GENESIS_LIVE_FIRE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="${GENESIS_LIVE_FIRE_OUT_DIR:-.genesis-state/live-fire/$RUN_ID}"
AUDIT_PATH=".genesis-state/audit.jsonl"
TMP_DIR="$(mktemp -d /tmp/genesis_v44_live_fire.XXXXXX)"
ORIGINAL_AUDIT=""
DYNAMIC_PID=""
LLM_PID=""
CORE_PID=""

log() {
    echo "[v4.4-live-fire] $*"
}

fail() {
    echo "[v4.4-live-fire] ERROR: $*" >&2
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
    if [[ -n "$ORIGINAL_AUDIT" && -f "$ORIGINAL_AUDIT" ]]; then
        mv "$ORIGINAL_AUDIT" "$AUDIT_PATH"
    fi
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket_path="$1"
    local label="$2"
    local max_wait="${3:-120}"
    for _ in $(seq 1 "$max_wait"); do
        if [[ -S "$socket_path" ]]; then
            log "$label ready: $socket_path"
            return
        fi
        sleep 0.5
    done
    fail "timed out waiting for $label"
}

wait_for_state() {
    local url="${GENESIS_SENSE_URL:-http://127.0.0.1:4781/state}"
    for _ in $(seq 1 120); do
        if "$PYTHON_BIN" -c "import urllib.request; urllib.request.urlopen('$url', timeout=0.25).read()" \
            >/dev/null 2>&1; then
            log "dynamic state endpoint ready: $url"
            return
        fi
        sleep 0.25
    done
    fail "timed out waiting for dynamic state endpoint"
}

print_banner() {
    echo "========================================================================"
    echo "Genesis v4.4 Real Model Live Fire Telemetry"
    echo "Model: ${GENESIS_MODEL_PATH:-Fallback/Test Mode}"
    echo "Duration: ${LIVE_FIRE_SEC}s"
    echo "Output: $OUT_DIR"
    echo "========================================================================"
}

print_banner

mkdir -p .genesis-state "$OUT_DIR"
if [[ -f "$AUDIT_PATH" ]]; then
    ORIGINAL_AUDIT="$TMP_DIR/audit.original.jsonl"
    mv "$AUDIT_PATH" "$ORIGINAL_AUDIT"
fi

log "sweeping dangling sockets"
rm -f /tmp/genesis_brain.sock /tmp/genesis_dynamic_act.sock

log "building core and ABI plugins"
cargo build -p genesis-core -p brain-llm -p anchor-mmap -p plugin-dummy
cp target/debug/libbrain_llm.dylib genesis-plugins/libbrain_llm.dylib
cp target/debug/libanchor_mmap.dylib genesis-plugins/libanchor_mmap.dylib
cp target/debug/libplugin_dummy.dylib genesis-plugins/libplugin_dummy.dylib

log "starting Dynamic Arena"
GENESIS_DYNAMIC_FPS="${GENESIS_DYNAMIC_FPS:-60}" \
GENESIS_DYNAMIC_TARGET_ID="${GENESIS_DYNAMIC_TARGET_ID:-heal}" \
    "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py \
    > "$OUT_DIR/arena.log" 2>&1 &
DYNAMIC_PID=$!
wait_for_socket /tmp/genesis_dynamic_act.sock "Dynamic actuator" 80
wait_for_state

log "starting LLM daemon"
if [[ -z "${GENESIS_MODEL_PATH:-}" ]]; then
    log "GENESIS_MODEL_PATH is not set; daemon will use deterministic fallback"
fi
GENESIS_ALLOWED_CLICK_TARGETS="${GENESIS_ALLOWED_CLICK_TARGETS:-heal}" \
GENESIS_ALLOWED_WAIT_SELECTORS="${GENESIS_ALLOWED_WAIT_SELECTORS:-heal}" \
    "$PYTHON_BIN" genesis-daemons/llm-daemon-python/llm_daemon.py \
    > "$OUT_DIR/llm.log" 2>&1 &
LLM_PID=$!
wait_for_socket /tmp/genesis_brain.sock "Brain daemon" 240

log "starting Genesis Core"
GENESIS_SENSE_URL="${GENESIS_SENSE_URL:-http://127.0.0.1:4781/state}" \
GENESIS_SENSE_KEY="${GENESIS_SENSE_KEY:-dynamic_state}" \
GENESIS_MACRO_GOAL="${GENESIS_MACRO_GOAL:-Use bounded dynamic evidence to interact with target heal in the current frame without bypassing verification}" \
    cargo run -p genesis-core > "$OUT_DIR/core.log" 2>&1 &
CORE_PID=$!

log "live fire engaged for ${LIVE_FIRE_SEC}s"
sleep "$LIVE_FIRE_SEC"

log "cease fire"
stop_run

[[ -f "$AUDIT_PATH" ]] || fail "live-fire audit was not created"
cp "$AUDIT_PATH" "$OUT_DIR/audit.jsonl"

log "projecting audit and extracting telemetry"
"$PYTHON_BIN" scripts/project_audit_sqlite.py \
    --rebuild \
    --audit "$OUT_DIR/audit.jsonl" \
    --db "$OUT_DIR/audit.sqlite" \
    --telemetry-report | tee "$OUT_DIR/telemetry.txt"

log "live fire complete"
echo "Artifacts:"
echo "  $OUT_DIR/audit.jsonl"
echo "  $OUT_DIR/audit.sqlite"
echo "  $OUT_DIR/telemetry.txt"
echo "  $OUT_DIR/core.log"
echo "  $OUT_DIR/llm.log"
echo "  $OUT_DIR/arena.log"

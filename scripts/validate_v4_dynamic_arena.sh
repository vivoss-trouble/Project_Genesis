#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PYTHON_BIN="${GENESIS_PYTHON:-python3}"
ARENA_PID=""

log() {
    echo "[v4-dynamic-arena] $*"
}

fail() {
    echo "[v4-dynamic-arena] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$ARENA_PID" ]] && kill -0 "$ARENA_PID" 2>/dev/null; then
        kill "$ARENA_PID" 2>/dev/null || true
        wait "$ARENA_PID" 2>/dev/null || true
    fi
    rm -f /tmp/genesis_dynamic_act.sock
}

trap cleanup EXIT INT TERM

wait_for_state() {
    for _ in $(seq 1 80); do
        if "$PYTHON_BIN" -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4781/state", timeout=0.2).read()' \
            >/dev/null 2>&1; then
            log "state endpoint ready"
            return
        fi
        sleep 0.1
    done
    fail "timed out waiting for state endpoint"
}

wait_for_socket() {
    for _ in $(seq 1 80); do
        if [[ -S /tmp/genesis_dynamic_act.sock ]]; then
            log "action socket ready"
            return
        fi
        sleep 0.1
    done
    fail "timed out waiting for action socket"
}

log "running pure engine selftest"
GENESIS_DYNAMIC_ARENA_SELFTEST=1 GENESIS_DYNAMIC_SELFTEST_MODE=1 \
    "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py

log "starting dynamic arena daemon"
GENESIS_DYNAMIC_SELFTEST_MODE=1 GENESIS_DYNAMIC_FPS=60 \
    "$PYTHON_BIN" genesis-daemons/dynamic-arena-python/dynamic_arena.py \
    > /tmp/genesis_dynamic_arena.log 2>&1 &
ARENA_PID=$!
wait_for_socket
wait_for_state

log "verifying committed frames and OCC verdicts"
"$PYTHON_BIN" <<'PY'
import json
import socket
import time
import urllib.request


def state():
    with urllib.request.urlopen("http://127.0.0.1:4781/state", timeout=1) as response:
        return json.loads(response.read())


def send(action):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect("/tmp/genesis_dynamic_act.sock")
        client.sendall(json.dumps(action).encode("utf-8") + b"\n")
        return json.loads(client.recv(4096))


first = state()
time.sleep(0.08)
second = state()
assert second["frame_id"] > first["frame_id"], (first, second)
assert second["sense_latency_ms"] >= 0, second
target = second["targets"][0]
hit = {
    "action_id": "validate-hit",
    "act": "click_point",
    "target_id": target["id"],
    "x": target["x"] + target["w"] / 2,
    "y": target["y"] + target["h"] / 2,
    "frame_id": second["frame_id"],
    "reason": "v4 validation current-frame hit",
}
assert send(hit)["status"] == "queued"
time.sleep(0.08)
verified = state()["last_verdict"]
assert verified["status"] == "Verified", verified
assert verified["action_id"] == "validate-hit", verified
assert verified["failure_kind"] is None, verified

miss = {
    "action_id": "validate-stale",
    "act": "click_point",
    "target_id": target["id"],
    "x": -10,
    "y": -10,
    "frame_id": max(0, state()["frame_id"] - 99),
    "reason": "v4 validation stale miss",
}
assert send(miss)["status"] == "queued"
time.sleep(0.08)
failed = state()["last_verdict"]
assert failed["status"] == "Failed", failed
assert failed["action_id"] == "validate-stale", failed
assert failed["failure_kind"] == "StaleFrame", failed
print("[v4-dynamic-arena] committed-frame OCC validation passed")
PY

log "Genesis v4 dynamic arena validation passed"

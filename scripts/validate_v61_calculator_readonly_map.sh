#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${GENESIS_V61_MAPPER_BIN:-/tmp/genesis_calculator_readonly_map}"
LOG_PATH="${GENESIS_V61_LOG:-/tmp/genesis_validate_v61_calculator_readonly_map.log}"
DEBUG_PNG="${GENESIS_V61_DEBUG_PNG:-/tmp/genesis_v61_debug.png}"
MIN_TARGETS="${GENESIS_V61_MIN_TARGETS:-12}"

echo "========================================================================"
echo "Genesis v6.1 Calculator Read-Only Vision Map Validation"
echo "========================================================================"

open -a Calculator || true
sleep "${GENESIS_V61_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/calculator_readonly_map.swift -o "$BIN_PATH"
GENESIS_V61_DEBUG_PNG="$DEBUG_PNG" "$BIN_PATH" | tee "$LOG_PATH"

python3 - "$LOG_PATH" "$DEBUG_PNG" "$MIN_TARGETS" <<'PY'
import json
import os
import sys

log_path, debug_png, min_targets_raw = sys.argv[1:4]
min_targets = int(min_targets_raw)
event = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "calculator_readonly_map":
            event = payload

if event is None:
    raise SystemExit("[v6.1] missing calculator_readonly_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v6.1] mapper returned error: {event}")
if event.get("capture_scope") != "window":
    raise SystemExit(f"[v6.1] expected window capture, got {event.get('capture_scope')}")
if event.get("posted") is not False:
    raise SystemExit(f"[v6.1] readonly mapper must never post actions: {event}")

targets = event.get("targets") or []
if len(targets) < min_targets:
    raise SystemExit(f"[v6.1] expected at least {min_targets} button targets, got {len(targets)}")
if event.get("row_count", 0) < 4:
    raise SystemExit(f"[v6.1] expected at least 4 grid rows, got {event.get('row_count')}")

for target in targets:
    target_id = target.get("target_id", "")
    point = target.get("global_coregraphics_point") or {}
    bbox = target.get("bbox") or {}
    if not target_id.startswith("calculator-cell-r"):
        raise SystemExit(f"[v6.1] target id is not grid-shaped: {target}")
    if point.get("x") is None or point.get("y") is None:
        raise SystemExit(f"[v6.1] target missing global point: {target}")
    if bbox.get("width", 0) <= 0 or bbox.get("height", 0) <= 0:
        raise SystemExit(f"[v6.1] target missing bbox: {target}")

if not os.path.exists(debug_png) or os.path.getsize(debug_png) <= 0:
    raise SystemExit(f"[v6.1] debug overlay was not written: {debug_png}")

print(json.dumps({
    "event": "v61_calculator_readonly_assertions",
    "target_count": len(targets),
    "row_count": event.get("row_count"),
    "first_target": targets[0]["target_id"],
    "debug_overlay": debug_png,
    "posted": event.get("posted"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.1 Calculator read-only vision map validation passed"
echo "Debug overlay: $DEBUG_PNG"
echo "========================================================================"

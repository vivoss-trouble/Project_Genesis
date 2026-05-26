#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${GENESIS_V71_MAPPER_BIN:-/tmp/genesis_v71_browser_fixture_readonly_map}"
LOG_PATH="${GENESIS_V71_LOG:-/tmp/genesis_validate_v71_browser_fixture_readonly_map.log}"
DEBUG_PNG="${GENESIS_V71_DEBUG_PNG:-/tmp/genesis_v71_browser_fixture_debug.png}"
FIXTURE_PATH="$ROOT_DIR/fixtures/v7/browser_fixture.html"
BROWSER_APP="${GENESIS_V71_BROWSER_APP:-Safari}"
MIN_TARGETS="${GENESIS_V71_MIN_TARGETS:-5}"

echo "========================================================================"
echo "Genesis v7.1 Browser Fixture Read-Only Vision Map Validation"
echo "========================================================================"

open -a "$BROWSER_APP" "file://$FIXTURE_PATH" || open "file://$FIXTURE_PATH"
sleep "${GENESIS_V71_BROWSER_SETTLE_SEC:-1.5}"

swiftc scripts/browser_fixture_readonly_map.swift -o "$BIN_PATH"
GENESIS_V71_DEBUG_PNG="$DEBUG_PNG" "$BIN_PATH" | tee "$LOG_PATH"

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
        if payload.get("event") == "browser_fixture_readonly_map":
            event = payload

if event is None:
    raise SystemExit("[v7.1] missing browser_fixture_readonly_map event")
if event.get("status") == "error":
    raise SystemExit(f"[v7.1] mapper returned error: {event}")
if event.get("capture_scope") != "window":
    raise SystemExit(f"[v7.1] expected window capture, got {event.get('capture_scope')}")
if event.get("posted") is not False:
    raise SystemExit(f"[v7.1] readonly mapper must never post actions: {event}")

targets = event.get("targets") or []
if len(targets) < min_targets:
    raise SystemExit(f"[v7.1] expected at least {min_targets} browser targets, got {len(targets)}")

kinds = {target.get("control_kind") for target in targets}
required = {"button-like", "input-like", "scroll-container", "async-target"}
missing = sorted(required - kinds)
if missing:
    raise SystemExit(f"[v7.1] missing control kinds {missing}; got {sorted(kinds)}")

for target in targets:
    target_id = target.get("target_id", "")
    point = target.get("global_coregraphics_point") or {}
    bbox = target.get("bbox") or {}
    if not target_id.startswith("browser-"):
        raise SystemExit(f"[v7.1] target id is not browser-shaped: {target}")
    if point.get("x") is None or point.get("y") is None:
        raise SystemExit(f"[v7.1] target missing global point: {target}")
    if bbox.get("width", 0) <= 0 or bbox.get("height", 0) <= 0:
        raise SystemExit(f"[v7.1] target missing bbox: {target}")

if not os.path.exists(debug_png) or os.path.getsize(debug_png) <= 0:
    raise SystemExit(f"[v7.1] debug overlay was not written: {debug_png}")

print(json.dumps({
    "event": "v71_browser_fixture_readonly_assertions",
    "target_count": len(targets),
    "control_kinds": sorted(kinds),
    "first_target": targets[0]["target_id"],
    "debug_overlay": debug_png,
    "posted": event.get("posted"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.1 Browser fixture read-only vision map validation passed"
echo "Debug overlay: $DEBUG_PNG"
echo "========================================================================"

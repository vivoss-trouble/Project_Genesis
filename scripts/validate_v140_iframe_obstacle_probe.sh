#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V140_LOG:-/tmp/genesis_validate_v140_iframe_obstacle_probe.log}"

echo "========================================================================"
echo "Genesis v14.0 Iframe Obstacle Probe Validation"
echo "========================================================================"

./scripts/run_v140_iframe_obstacle_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

same = next((event for event in events if event.get("event") == "v140_same_origin_iframe_summary"), None)
sandbox = next((event for event in events if event.get("event") == "v140_sandbox_iframe_summary"), None)
summary = next((event for event in events if event.get("event") == "v140_iframe_obstacle_summary"), None)

if same is None:
    raise SystemExit("[v14.0] missing same-origin iframe summary")
if sandbox is None:
    raise SystemExit("[v14.0] missing sandbox iframe summary")
if summary is None:
    raise SystemExit("[v14.0] missing final iframe summary")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v14.0] dry-run validation must not post: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.0] dry-run validation leaked physical input: {payload}")

if same.get("penetration_model_ok") is not True:
    raise SystemExit(f"[v14.0] same-origin iframe penetration failed: {same}")
if same.get("candidate_count") != 4:
    raise SystemExit(f"[v14.0] same-origin candidate count mismatch: {same}")
if same.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v14.0] same-origin legal candidate count mismatch: {same}")
if same.get("rejected_candidate_count") != 3:
    raise SystemExit(f"[v14.0] same-origin rejected candidate count mismatch: {same}")
if same.get("click_posted") is not False:
    raise SystemExit(f"[v14.0] dry-run same-origin branch clicked: {same}")

if sandbox.get("sandbox_safe_death") is not True:
    raise SystemExit(f"[v14.0] sandbox iframe did not safe-death: {sandbox}")
if sandbox.get("occluder_kind") != "iframe":
    raise SystemExit(f"[v14.0] sandbox occluder kind mismatch: {sandbox}")
if sandbox.get("candidate_count") != 0:
    raise SystemExit(f"[v14.0] sandbox should expose no clearance candidates: {sandbox}")
if sandbox.get("stop_reason") != "iframe_occluder_unresolved":
    raise SystemExit(f"[v14.0] sandbox stop reason mismatch: {sandbox}")

if summary.get("iframe_probe_complete") is not True:
    raise SystemExit(f"[v14.0] final summary did not complete: {summary}")

print(json.dumps({
    "event": "v140_iframe_obstacle_assertions",
    "same_origin_penetration_ok": True,
    "same_origin_candidate_count": 4,
    "same_origin_legal_candidate_count": 1,
    "sandbox_safe_death": True,
    "sandbox_stop_reason": "iframe_occluder_unresolved",
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.0 iframe obstacle probe validation passed"
echo "========================================================================"

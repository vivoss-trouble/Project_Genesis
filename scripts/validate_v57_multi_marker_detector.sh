#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V57_LOG:-/tmp/genesis_validate_v57_multi_marker_detector.log}"

echo "========================================================================"
echo "Genesis v5.7 Multi-Marker Detector Validation"
echo "========================================================================"

GENESIS_V55_AUTO_VISIBLE=1 \
    ./scripts/run_v55_vision_marker_single_shot.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
vision_state = None
action_point = None
posted_values = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if payload.get("event") == "vision_marker_state":
            vision_state = payload
        if payload.get("event") == "vision_action_point":
            action_point = payload
        for key in ("move", "click"):
            receipt = payload.get(key, {}).get("receipt")
            if isinstance(receipt, dict) and "posted" in receipt:
                posted_values.append(receipt["posted"])

if vision_state is None:
    raise SystemExit("[v5.7] missing vision_marker_state event")
if vision_state.get("capture_scope") != "window":
    raise SystemExit(f"[v5.7] expected window capture, got {vision_state.get('capture_scope')!r}")

candidates = vision_state.get("marker_candidates")
if not isinstance(candidates, list) or len(candidates) < 3:
    raise SystemExit(f"[v5.7] expected at least 3 marker candidates, got {candidates!r}")

for index, candidate in enumerate(candidates[:3]):
    for field in ("candidate_id", "pixel_center", "coregraphics_logical_center", "appkit_logical_center", "bbox", "pixel_count"):
        if field not in candidate:
            raise SystemExit(f"[v5.7] candidate {index} missing {field}")
    bbox = candidate["bbox"]
    if bbox.get("width", 0) <= 0 or bbox.get("height", 0) <= 0:
        raise SystemExit(f"[v5.7] candidate {index} has invalid bbox {bbox!r}")
    if candidate["pixel_count"] <= 0:
        raise SystemExit(f"[v5.7] candidate {index} has invalid pixel_count")

xs = [candidate["coregraphics_logical_center"]["x"] for candidate in candidates[:3]]
if xs != sorted(xs):
    raise SystemExit(f"[v5.7] expected left-to-right deterministic ordering, got {xs!r}")

if action_point is None:
    raise SystemExit("[v5.7] missing transformed vision_action_point")
if not posted_values or any(posted_values):
    raise SystemExit(f"[v5.7] validation must remain dry-run, posted values={posted_values!r}")

print(json.dumps({
    "event": "v57_multi_marker_assertions",
    "candidate_count": len(candidates),
    "selected_candidate": candidates[0]["candidate_id"],
    "ordered_x": xs,
    "posted_values": posted_values,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v5.7 multi-marker detector validation passed"
echo "========================================================================"

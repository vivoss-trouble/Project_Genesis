#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V130_LOG:-/tmp/genesis_validate_v130_obstacle_clearance_probe.log}"

echo "========================================================================"
echo "Genesis v13.0 Obstacle Clearance Probe Validation"
echo "========================================================================"

./scripts/run_v130_obstacle_clearance_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

probe = next((event for event in events if event.get("event") == "v130_obstacle_clearance_probe"), None)
summary = next((event for event in events if event.get("event") == "v130_obstacle_clearance_summary"), None)

if probe is None:
    raise SystemExit("[v13.0] missing obstacle clearance probe event")
if summary is None:
    raise SystemExit("[v13.0] missing obstacle clearance summary")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v13.0] validation must not post: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v13.0] validation must not post physical input: {payload}")

if probe.get("target_found") is not True:
    raise SystemExit(f"[v13.0] target not found: {probe}")
if probe.get("occlusion_clear") is not False:
    raise SystemExit(f"[v13.0] fixture target should be occluded: {probe}")
if probe.get("candidate_count") != 4:
    raise SystemExit(f"[v13.0] expected exactly four candidate controls: {probe}")
if probe.get("legal_candidate_count") != 1:
    raise SystemExit(f"[v13.0] expected exactly one legal candidate: {probe}")
if probe.get("rejected_candidate_count") != 3:
    raise SystemExit(f"[v13.0] expected three rejected trap candidates: {probe}")
if probe.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v13.0] dry-run attempted AX mutation: {probe}")

selected = probe.get("selected_clearance") or {}
label = " ".join(str(selected.get(k) or "") for k in ("title", "description", "value")).strip().lower()
if "close" not in label:
    raise SystemExit(f"[v13.0] selected clearance is not Close: {probe}")

for candidate in probe.get("candidates") or []:
    label = (candidate.get("label") or "").lower()
    if any(term in label for term in ("accept", "subscribe", "continue")):
        if candidate.get("legal_candidate") is True:
            raise SystemExit(f"[v13.0] trap candidate survived whitelist court: {candidate}")

if summary.get("stop_reason") != "dry_run_projection_stop":
    raise SystemExit(f"[v13.0] dry-run did not stop at projection boundary: {summary}")
if summary.get("click_posted") is not False:
    raise SystemExit(f"[v13.0] dry-run posted click: {summary}")

print(json.dumps({
    "event": "v130_obstacle_clearance_assertions",
    "target_occluded_before": True,
    "candidate_count": 4,
    "legal_candidate_count": 1,
    "rejected_candidate_count": 3,
    "selected_clearance": "Close",
    "ax_mutation_attempted": False,
    "click_posted": False,
    "stop_reason": "dry_run_projection_stop",
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v13.0 obstacle clearance probe validation passed"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V64_LOG:-/tmp/genesis_validate_v64_calculator_frame_stability.log}"

echo "========================================================================"
echo "Genesis v6.4 Calculator Frame Stability Probe Validation"
echo "========================================================================"

./scripts/probe_v64_calculator_frame_stability.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
start = None
samples = []
summary = None

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "frame_stability_probe_start":
            start = payload
        elif event == "frame_stability_probe":
            samples.append(payload)
        elif event == "frame_stability_summary":
            summary = payload

if start is None:
    raise SystemExit("[v6.4] missing frame_stability_probe_start")
if start.get("posted") is not False:
    raise SystemExit(f"[v6.4] probe must remain read-only: {start}")
if not samples:
    raise SystemExit("[v6.4] missing frame stability samples")
if any(sample.get("posted") is not False for sample in samples):
    raise SystemExit(f"[v6.4] sample attempted to post action: {samples}")
if summary is None:
    raise SystemExit("[v6.4] missing frame_stability_summary")
if summary.get("posted") is not False:
    raise SystemExit(f"[v6.4] summary attempted to post action: {summary}")
if summary.get("stable") is not True:
    raise SystemExit(f"[v6.4] Calculator did not stabilize: {summary}")
if summary.get("stable_run", 0) < start.get("stable_frames_required", 3):
    raise SystemExit(f"[v6.4] stable run too short: start={start} summary={summary}")
if summary.get("elapsed_ms", 999999) > start.get("max_wait_ms", 1500):
    raise SystemExit(f"[v6.4] probe exceeded max wait: start={start} summary={summary}")

print(json.dumps({
    "event": "v64_frame_stability_assertions",
    "sample_count": len(samples),
    "stable_run": summary.get("stable_run"),
    "elapsed_ms": summary.get("elapsed_ms"),
    "last_changed_pixel_ratio": summary.get("last_changed_pixel_ratio"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v6.4 Calculator frame stability probe validation passed"
echo "========================================================================"

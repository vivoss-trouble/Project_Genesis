#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V82_LOG:-/tmp/genesis_validate_v82_open_web_drift.log}"

echo "========================================================================"
echo "Genesis v8.2 Open-Web Drift Telemetry Validation"
echo "========================================================================"

GENESIS_V82_SAMPLE_COUNT="${GENESIS_V82_SAMPLE_COUNT:-5}" \
GENESIS_V82_SAMPLE_INTERVAL_SEC="${GENESIS_V82_SAMPLE_INTERVAL_SEC:-0.08}" \
  ./scripts/run_v82_open_web_drift_telemetry.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import pathlib
import sys

log_path = sys.argv[1]
summary = None
frame_events = []
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            frame_events.append(payload)
        elif payload.get("event") == "open_web_drift_telemetry":
            summary = payload

if summary is None:
    raise SystemExit("[v8.2] missing drift telemetry summary")
if summary.get("posted") is not False:
    raise SystemExit(f"[v8.2] drift telemetry must not post: {summary}")
if summary.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.2] os-driver must remain disconnected: {summary}")
if summary.get("frame_count") != len(frame_events):
    raise SystemExit(f"[v8.2] frame_count mismatch: {summary.get('frame_count')} vs {len(frame_events)}")
if summary.get("frame_count", 0) < 3:
    raise SystemExit(f"[v8.2] expected at least 3 frames: {summary}")

required = {"heading", "link-like", "button-like", "code-block", "scroll-region"}
for index, event in enumerate(frame_events):
    if event.get("posted") is not False or event.get("os_driver_active") is not False:
        raise SystemExit(f"[v8.2] frame {index} mutated world: {event}")
    kinds = set(event.get("control_kinds") or [])
    missing = sorted(required - kinds)
    if missing:
        raise SystemExit(f"[v8.2] frame {index} missing taxonomy classes {missing}")

if summary.get("max_kind_switch_count", 0) != 0:
    raise SystemExit(f"[v8.2] static baseline must not flicker taxonomy: {summary}")
if summary.get("missing_observations", 0) != 0:
    raise SystemExit(f"[v8.2] static baseline must not lose targets: {summary}")
if float(summary.get("max_centroid_drift_px") or 0.0) > 0.5:
    raise SystemExit(f"[v8.2] static baseline drift too high: {summary}")

output_dir = pathlib.Path(summary.get("output_dir", ""))
if not output_dir.exists():
    raise SystemExit(f"[v8.2] output_dir missing: {output_dir}")

print(json.dumps({
    "event": "v82_open_web_drift_telemetry_assertions",
    "frame_count": summary.get("frame_count"),
    "max_centroid_drift_px": summary.get("max_centroid_drift_px"),
    "max_window_origin_drift_px": summary.get("max_window_origin_drift_px"),
    "missing_observations": summary.get("missing_observations"),
    "max_kind_switch_count": summary.get("max_kind_switch_count"),
    "posted": False,
    "os_driver_active": False,
    "output_dir": str(output_dir),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.2 open-web drift telemetry validation passed"
echo "========================================================================"

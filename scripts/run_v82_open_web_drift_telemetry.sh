#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V82_MAPPER_BIN:-/tmp/genesis_v82_open_web_shadow_map}"
TARGET_URL="${GENESIS_V82_URL:-file://$ROOT_DIR/fixtures/v8/open_web_shadow_sample.html}"
BROWSER_APP="${GENESIS_V82_BROWSER_APP:-Safari}"
SAMPLE_COUNT="${GENESIS_V82_SAMPLE_COUNT:-5}"
SAMPLE_INTERVAL_SEC="${GENESIS_V82_SAMPLE_INTERVAL_SEC:-0.12}"
OUTPUT_DIR="${GENESIS_V82_OUTPUT_DIR:-/tmp/genesis_v82_open_web_drift}"
OPEN_BROWSER="${GENESIS_V82_OPEN_BROWSER:-1}"

open_target_url() {
    local url="$1"
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$url" <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        open location targetUrl
    end tell
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

echo "========================================================================"
echo "Genesis v8.2 Open-Web Drift Telemetry"
echo "========================================================================"
echo "[v8.2] URL: $TARGET_URL"
echo "[v8.2] Samples: $SAMPLE_COUNT"
echo "[v8.2] Interval: ${SAMPLE_INTERVAL_SEC}s"
echo "[v8.2] Output: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"

if [[ "$OPEN_BROWSER" == "1" ]]; then
    open_target_url "$TARGET_URL"
    sleep "${GENESIS_V82_BROWSER_SETTLE_SEC:-1.5}"
fi

for index in $(seq 0 $((SAMPLE_COUNT - 1))); do
    debug_path="$OUTPUT_DIR/frame_${index}.png"
    json_path="$OUTPUT_DIR/frame_${index}.jsonl"
    GENESIS_V81_DEBUG_PNG="$debug_path" "$MAPPER_BIN" | tee "$json_path"
    if [[ "$index" -lt $((SAMPLE_COUNT - 1)) ]]; then
        sleep "$SAMPLE_INTERVAL_SEC"
    fi
done

python3 - "$OUTPUT_DIR" <<'PY'
import json
import math
import pathlib
import statistics
import sys

output_dir = pathlib.Path(sys.argv[1])
frames = []
for path in sorted(output_dir.glob("frame_*.jsonl")):
    event = None
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw.startswith("{"):
                continue
            payload = json.loads(raw)
            if payload.get("event") == "open_web_shadow_map":
                event = payload
    if event is None:
        raise SystemExit(f"[v8.2] missing shadow map event in {path}")
    if event.get("status") == "error":
        raise SystemExit(f"[v8.2] mapper error in {path}: {event}")
    if event.get("posted") is not False or event.get("os_driver_active") is not False:
        raise SystemExit(f"[v8.2] drift telemetry must remain read-only: {event}")
    frames.append(event)

if not frames:
    raise SystemExit("[v8.2] no frames captured")

def target_by_id(frame):
    return {target["target_id"]: target for target in frame.get("targets") or []}

baseline = target_by_id(frames[0])
baseline_ids = sorted(baseline.keys())
observed_ids = sorted(set().union(*(target_by_id(frame).keys() for frame in frames)))
new_target_observations = sum(1 for target_id in observed_ids if target_id not in baseline)
target_stats = []
for target_id in baseline_ids:
    observations = []
    kinds = []
    for frame_index, frame in enumerate(frames):
        target = target_by_id(frame).get(target_id)
        if not target:
            continue
        point = target["window_coregraphics_point"]
        observations.append((frame_index, float(point["x"]), float(point["y"])))
        kinds.append(target.get("control_kind"))

    if len(observations) < 2:
        max_drift = 0.0
        mean_drift = 0.0
        stddev_drift = 0.0
    else:
        _, base_x, base_y = observations[0]
        drifts = [math.hypot(x - base_x, y - base_y) for _, x, y in observations]
        max_drift = max(drifts)
        mean_drift = statistics.fmean(drifts)
        stddev_drift = statistics.pstdev(drifts)

    target_stats.append({
        "target_id": target_id,
        "control_kind": baseline.get(target_id, {}).get("control_kind") or (kinds[0] if kinds else None),
        "observed_frames": len(observations),
        "missing_frames": len(frames) - len(observations),
        "kind_switch_count": max(0, len(set(kinds)) - 1),
        "mean_centroid_drift_px": mean_drift,
        "max_centroid_drift_px": max_drift,
        "stddev_centroid_drift_px": stddev_drift,
    })

window_origins = [
    (
        float(frame.get("window_bounds", {}).get("x") or 0.0),
        float(frame.get("window_bounds", {}).get("y") or 0.0),
    )
    for frame in frames
]
base_window_x, base_window_y = window_origins[0]
window_origin_drifts = [
    math.hypot(x - base_window_x, y - base_window_y)
    for x, y in window_origins
]

max_drift = max((stat["max_centroid_drift_px"] for stat in target_stats), default=0.0)
max_kind_switch = max((stat["kind_switch_count"] for stat in target_stats), default=0)
missing_observations = sum(stat["missing_frames"] for stat in target_stats)
capture_latencies = [float(frame.get("capture_latency_ms") or 0.0) for frame in frames]
summary = {
    "event": "open_web_drift_telemetry",
    "frame_count": len(frames),
    "target_ids": baseline_ids,
    "observed_target_ids": observed_ids,
    "target_count_baseline": len(baseline),
    "new_target_observations": new_target_observations,
    "target_stats": target_stats,
    "max_centroid_drift_px": max_drift,
    "max_window_origin_drift_px": max(window_origin_drifts) if window_origin_drifts else 0.0,
    "max_kind_switch_count": max_kind_switch,
    "missing_observations": missing_observations,
    "mean_capture_latency_ms": statistics.fmean(capture_latencies) if capture_latencies else 0.0,
    "max_capture_latency_ms": max(capture_latencies) if capture_latencies else 0.0,
    "posted": False,
    "os_driver_active": False,
    "output_dir": str(output_dir),
}
print(json.dumps(summary, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.2 open-web drift telemetry complete"
echo "========================================================================"

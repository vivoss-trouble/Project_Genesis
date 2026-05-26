#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET_URL="${GENESIS_V83_URL:-https://doc.rust-lang.org/book/}"
WINDOW_TITLE="${GENESIS_V83_WINDOW_TITLE:-Rust}"
SAMPLE_COUNT="${GENESIS_V83_SAMPLE_COUNT:-10}"
SAMPLE_INTERVAL_SEC="${GENESIS_V83_SAMPLE_INTERVAL_SEC:-0.2}"
OUTPUT_DIR="${GENESIS_V83_OUTPUT_DIR:-/tmp/genesis_v83_open_web_recon}"
DRIFT_LOG="$OUTPUT_DIR/drift.log"

echo "========================================================================"
echo "Genesis v8.3 Open-Web Recon Probe"
echo "========================================================================"
echo "[v8.3] URL: $TARGET_URL"
echo "[v8.3] Window title needle: $WINDOW_TITLE"
echo "[v8.3] Samples: $SAMPLE_COUNT"
echo "[v8.3] Interval: ${SAMPLE_INTERVAL_SEC}s"
echo "[v8.3] Output: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

GENESIS_V82_URL="$TARGET_URL" \
GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V82_SAMPLE_COUNT="$SAMPLE_COUNT" \
GENESIS_V82_SAMPLE_INTERVAL_SEC="$SAMPLE_INTERVAL_SEC" \
GENESIS_V82_OUTPUT_DIR="$OUTPUT_DIR/frames" \
  ./scripts/run_v82_open_web_drift_telemetry.sh | tee "$DRIFT_LOG"

python3 - "$DRIFT_LOG" "$TARGET_URL" "$OUTPUT_DIR" <<'PY'
import datetime as dt
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
target_url = sys.argv[2]
output_dir = pathlib.Path(sys.argv[3])

frames = []
summary = None
with log_path.open("r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            frames.append(payload)
        elif payload.get("event") == "open_web_drift_telemetry":
            summary = payload

if summary is None:
    raise SystemExit("[v8.3] missing v8.2 drift telemetry summary")
if not frames:
    raise SystemExit("[v8.3] missing shadow map frames")
if summary.get("posted") is not False or summary.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.3] recon must remain read-only: {summary}")

taxonomy = ["heading", "link-like", "button-like", "code-block", "scroll-region", "sticky-like"]
kind_counts = {kind: 0 for kind in taxonomy}
for target in frames[-1].get("targets") or []:
    kind = target.get("control_kind")
    if kind in kind_counts:
        kind_counts[kind] += 1

coverage = {kind: (1.0 if count > 0 else 0.0) for kind, count in kind_counts.items()}
taxonomy_gap = [kind for kind, value in coverage.items() if value == 0.0]
max_content_drift = float(summary.get("max_centroid_drift_px") or 0.0)
max_window_drift = float(summary.get("max_window_origin_drift_px") or 0.0)
kind_switches = int(summary.get("max_kind_switch_count") or 0)
missing = int(summary.get("missing_observations") or 0)
new_observations = int(summary.get("new_target_observations") or 0)
mean_latency = float(summary.get("mean_capture_latency_ms") or 0.0)

threats = []
if taxonomy_gap:
    threats.append("taxonomy_gap")
if max_content_drift > 0.75:
    threats.append("content_drift")
if kind_switches > 0:
    threats.append("taxonomy_flicker")
if missing > 0:
    threats.append("missing_targets")
if mean_latency > 250.0:
    threats.append("capture_latency")

safe = not threats
report = {
    "event": "open_web_recon_risk_report",
    "recon_timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
    "target_url": target_url,
    "metrics": {
        "target_count": frames[-1].get("target_count"),
        "taxonomy_coverage": coverage,
        "taxonomy_counts": kind_counts,
        "drift": {
            "max_content_drift_px": max_content_drift,
            "max_window_origin_drift_px": max_window_drift,
        },
        "stability": {
            "kind_switch_count": kind_switches,
            "missing_observations": missing,
            "new_target_observations": new_observations,
            "mean_capture_latency_ms": mean_latency,
            "max_capture_latency_ms": summary.get("max_capture_latency_ms"),
        },
        "frame_count": summary.get("frame_count"),
    },
    "risk_assessment": {
        "safe_to_consider_fire": safe,
        "primary_threat": threats[0] if threats else "none",
        "threats": threats,
    },
    "posted": False,
    "os_driver_active": False,
    "source_drift_summary": summary,
    "output_dir": str(output_dir),
}

report_path = output_dir / "risk_report.json"
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(report, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.3 open-web recon probe complete"
echo "========================================================================"

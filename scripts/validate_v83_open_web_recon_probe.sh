#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V83_LOG:-/tmp/genesis_validate_v83_open_web_recon.log}"

echo "========================================================================"
echo "Genesis v8.3 Open-Web Recon Probe Validation"
echo "========================================================================"

GENESIS_V83_URL="file://$ROOT_DIR/fixtures/v8/open_web_shadow_sample.html" \
GENESIS_V83_WINDOW_TITLE="Genesis v8.1 Shadow Mapping Sample" \
GENESIS_V83_SAMPLE_COUNT="${GENESIS_V83_SAMPLE_COUNT:-5}" \
GENESIS_V83_SAMPLE_INTERVAL_SEC="${GENESIS_V83_SAMPLE_INTERVAL_SEC:-0.08}" \
GENESIS_V83_OUTPUT_DIR="${GENESIS_V83_OUTPUT_DIR:-/tmp/genesis_v83_open_web_recon_validate}" \
  ./scripts/run_v83_open_web_recon_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
report = None
with log_path.open("r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_recon_risk_report":
            report = payload

if report is None:
    raise SystemExit("[v8.3] missing risk report")
if report.get("posted") is not False:
    raise SystemExit(f"[v8.3] recon must not post: {report}")
if report.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.3] os-driver must remain disconnected: {report}")

coverage = report.get("metrics", {}).get("taxonomy_coverage", {})
required = {"heading", "link-like", "button-like", "code-block", "scroll-region"}
missing = sorted(kind for kind in required if coverage.get(kind) != 1.0)
if missing:
    raise SystemExit(f"[v8.3] local recon missing taxonomy coverage {missing}: {report}")

risk = report.get("risk_assessment", {})
if risk.get("safe_to_consider_fire") is not True:
    raise SystemExit(f"[v8.3] local deterministic sample should be safe: {report}")
if risk.get("primary_threat") != "none":
    raise SystemExit(f"[v8.3] local deterministic sample should have no primary threat: {report}")

output_dir = pathlib.Path(report.get("output_dir", ""))
risk_path = output_dir / "risk_report.json"
if not risk_path.exists():
    raise SystemExit(f"[v8.3] risk report file missing: {risk_path}")

print(json.dumps({
    "event": "v83_open_web_recon_probe_assertions",
    "safe_to_consider_fire": risk.get("safe_to_consider_fire"),
    "primary_threat": risk.get("primary_threat"),
    "posted": False,
    "os_driver_active": False,
    "risk_report": str(risk_path),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.3 open-web recon probe validation passed"
echo "========================================================================"

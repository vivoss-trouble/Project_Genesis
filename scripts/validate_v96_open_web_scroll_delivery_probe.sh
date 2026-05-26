#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V96_LOG:-/tmp/genesis_validate_v96_open_web_scroll_delivery_probe.log}"

echo "========================================================================"
echo "Genesis v9.6 Open-Web Scroll Delivery Probe Validation"
echo "========================================================================"

GENESIS_V96_SCROLL_VARIANTS="${GENESIS_V96_SCROLL_VARIANTS:-pixel:66,line:3}" \
    ./scripts/run_v96_open_web_scroll_delivery_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
variants = []
scrolls = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v96_scroll_delivery_variant":
            variants.append(payload)
        elif event == "os_driver_scroll":
            scrolls.append(payload)
        elif event == "v96_open_web_scroll_delivery_probe_summary":
            summary = payload

if summary is None:
    raise SystemExit("[v9.6] missing scroll delivery summary")
if len(variants) != 2:
    raise SystemExit(f"[v9.6] validation expected two variants: {variants}")
if len(scrolls) != 2:
    raise SystemExit(f"[v9.6] validation expected two scroll receipts: {scrolls}")

units = {item.get("receipt_scroll_unit") for item in variants}
if units != {"pixel", "line"}:
    raise SystemExit(f"[v9.6] scroll unit receipts did not cover pixel+line: {variants}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v9.6] validation must remain dry-run: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v9.6] dry-run leaked physical posting: {summary}")
if summary.get("url_changed") is not False:
    raise SystemExit(f"[v9.6] dry-run changed URL: {summary}")

for item in variants:
    if item.get("scroll_status") != "ok":
        raise SystemExit(f"[v9.6] scroll request failed: {item}")
    if item.get("scroll_posted") is not False:
        raise SystemExit(f"[v9.6] variant leaked physical posting: {item}")
    if item.get("url_changed") is not False:
        raise SystemExit(f"[v9.6] variant changed URL: {item}")

print(json.dumps({
    "event": "v96_open_web_scroll_delivery_probe_assertions",
    "variant_count": len(variants),
    "scroll_units": sorted(units),
    "posted": False,
    "url_changed": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.6 open-web scroll delivery probe validation passed"
echo "========================================================================"

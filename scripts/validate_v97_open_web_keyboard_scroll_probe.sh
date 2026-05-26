#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V97_LOG:-/tmp/genesis_validate_v97_open_web_keyboard_scroll_probe.log}"

echo "========================================================================"
echo "Genesis v9.7 Open-Web Keyboard Scroll Probe Validation"
echo "========================================================================"

GENESIS_V97_KEY_VARIANTS="${GENESIS_V97_KEY_VARIANTS:-page_down,space,arrow_down}" \
    ./scripts/run_v97_open_web_keyboard_scroll_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
variants = []
keys = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v97_keyboard_scroll_variant":
            variants.append(payload)
        elif event == "os_driver_key":
            keys.append(payload)
        elif event == "v97_open_web_keyboard_scroll_probe_summary":
            summary = payload

if summary is None:
    raise SystemExit("[v9.7] missing keyboard scroll summary")
if len(variants) != 3:
    raise SystemExit(f"[v9.7] validation expected three variants: {variants}")
if len(keys) != 3:
    raise SystemExit(f"[v9.7] validation expected three key receipts: {keys}")

requested = {item.get("requested_key") for item in variants}
receipt_keys = {item.get("receipt_key", {}).get("key") for item in variants}
expected = {"page_down", "space", "arrow_down"}
if requested != expected or receipt_keys != expected:
    raise SystemExit(f"[v9.7] key receipts did not cover expected set: {variants}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v9.7] validation must remain dry-run: {summary}")
if summary.get("posted") is not False:
    raise SystemExit(f"[v9.7] dry-run leaked physical posting: {summary}")
if summary.get("url_changed") is not False:
    raise SystemExit(f"[v9.7] dry-run changed URL: {summary}")

for item in variants:
    if item.get("key_status") != "ok":
        raise SystemExit(f"[v9.7] key request failed: {item}")
    if item.get("key_posted") is not False:
        raise SystemExit(f"[v9.7] variant leaked physical posting: {item}")
    if item.get("url_changed") is not False:
        raise SystemExit(f"[v9.7] variant changed URL: {item}")

print(json.dumps({
    "event": "v97_open_web_keyboard_scroll_probe_assertions",
    "variant_count": len(variants),
    "keys": sorted(receipt_keys),
    "posted": False,
    "url_changed": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.7 open-web keyboard scroll probe validation passed"
echo "========================================================================"

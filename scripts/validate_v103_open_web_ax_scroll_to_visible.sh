#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V103_LOG:-/tmp/genesis_validate_v103_open_web_ax_scroll_to_visible.log}"

echo "========================================================================"
echo "Genesis v10.3 Open-Web AX ScrollToVisible Validation"
echo "========================================================================"

./scripts/run_v103_open_web_ax_scroll_to_visible.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
probe = None
result = None
summary = None
maps = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "v103_ax_scroll_to_visible_probe":
            probe = payload
        elif event == "v103_ax_scroll_to_visible_result":
            result = payload
        elif event == "v103_open_web_ax_scroll_to_visible_summary":
            summary = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if probe is None:
    raise SystemExit("[v10.3] missing AX ScrollToVisible probe event")
if result is None:
    raise SystemExit("[v10.3] missing AX ScrollToVisible result")
if summary is None:
    raise SystemExit("[v10.3] missing AX ScrollToVisible summary")
if len(maps) != 2:
    raise SystemExit(f"[v10.3] expected pre/post maps: {len(maps)}")

for payload in [probe, result, summary, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v10.3] probe must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v10.3] probe must keep os-driver inactive: {payload}")

if probe.get("status") != "ok":
    raise SystemExit(f"[v10.3] AX probe failed: {probe}")
if probe.get("web_area_found") is not True:
    raise SystemExit(f"[v10.3] AXWebArea was not found: {probe}")
if probe.get("target_found") is not True:
    raise SystemExit(f"[v10.3] target descendant was not found: {probe}")
if probe.get("scroll_to_visible_available") is not True:
    raise SystemExit(f"[v10.3] target does not expose AXScrollToVisible: {probe}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v10.3] target window changed during probe: {result}")
if result.get("url_changed_after_ax") is not False:
    raise SystemExit(f"[v10.3] dry-run changed URL: {result}")
if result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.3] dry-run attempted AX mutation: {result}")
if result.get("visual_change_detected") is not False:
    raise SystemExit(f"[v10.3] dry-run changed visual topology: {result}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v10.3] validation must remain dry-run: {summary}")

print(json.dumps({
    "event": "v103_open_web_ax_scroll_to_visible_assertions",
    "web_area_found": True,
    "target_found": True,
    "scroll_to_visible_available": True,
    "window_id_stable": True,
    "url_changed_after_ax": False,
    "ax_mutation_attempted": False,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v10.3 open-web AX ScrollToVisible validation passed"
echo "========================================================================"

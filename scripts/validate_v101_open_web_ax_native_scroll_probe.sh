#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V101_LOG:-/tmp/genesis_validate_v101_open_web_ax_native_scroll_probe.log}"

echo "========================================================================"
echo "Genesis v10.1 Open-Web AX Native Scroll Probe Validation"
echo "========================================================================"

./scripts/run_v101_open_web_ax_native_scroll_probe.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
ax = None
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
        if event == "v101_ax_native_scroll_probe":
            ax = payload
        elif event == "v101_ax_native_scroll_probe_result":
            result = payload
        elif event == "v101_open_web_ax_native_scroll_probe_summary":
            summary = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if ax is None:
    raise SystemExit("[v10.1] missing AX native scroll probe event")
if result is None:
    raise SystemExit("[v10.1] missing AX native scroll result")
if summary is None:
    raise SystemExit("[v10.1] missing AX native scroll summary")
if len(maps) != 2:
    raise SystemExit(f"[v10.1] expected pre/post AX maps: {len(maps)}")

for payload in [ax, *maps, result, summary]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v10.1] validation must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v10.1] validation must keep os-driver inactive: {payload}")

if ax.get("status") != "ok":
    raise SystemExit(f"[v10.1] AX native scroll probe failed: {ax}")
if ax.get("web_area_found") is not True:
    raise SystemExit(f"[v10.1] AXWebArea was not found: {ax}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v10.1] target window changed during probe: {result}")
if result.get("url_changed_after_ax") is not False:
    raise SystemExit(f"[v10.1] dry-run AX probe changed URL: {result}")
if result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.1] dry-run attempted AX mutation: {result}")
if result.get("visual_change_detected") is not False:
    raise SystemExit(f"[v10.1] dry-run changed visual topology: {result}")
if summary.get("armed") is not False:
    raise SystemExit(f"[v10.1] validation must remain dry-run: {summary}")

print(json.dumps({
    "event": "v101_open_web_ax_native_scroll_probe_assertions",
    "web_area_found": result.get("web_area_found"),
    "scroll_area_found": result.get("scroll_area_found"),
    "vertical_scrollbar_found": result.get("vertical_scrollbar_found"),
    "selected_primitive": result.get("selected_primitive"),
    "selected_action_target": result.get("selected_action_target"),
    "ax_mutation_attempted": False,
    "url_changed_after_ax": False,
    "window_id_stable": True,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v10.1 open-web AX native scroll probe validation passed"
echo "========================================================================"

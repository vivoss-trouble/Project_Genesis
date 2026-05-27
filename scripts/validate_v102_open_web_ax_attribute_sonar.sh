#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V102_LOG:-/tmp/genesis_validate_v102_open_web_ax_attribute_sonar.log}"

echo "========================================================================"
echo "Genesis v10.2 Open-Web AX Attribute Sonar Validation"
echo "========================================================================"

./scripts/run_v102_open_web_ax_attribute_sonar.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
sonar = None
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
        if event == "v102_ax_webarea_attribute_sonar":
            sonar = payload
        elif event == "v102_ax_attribute_sonar_result":
            result = payload
        elif event == "v102_open_web_ax_attribute_sonar_summary":
            summary = payload
        elif event == "open_web_shadow_map":
            maps.append(payload)

if sonar is None:
    raise SystemExit("[v10.2] missing AX attribute sonar event")
if result is None:
    raise SystemExit("[v10.2] missing AX attribute sonar result")
if summary is None:
    raise SystemExit("[v10.2] missing AX attribute sonar summary")
if len(maps) != 2:
    raise SystemExit(f"[v10.2] expected pre/post sonar maps: {len(maps)}")

for payload in [sonar, result, summary, *maps]:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v10.2] sonar must not post physical input: {payload}")
    if payload.get("os_driver_active") is not False:
        raise SystemExit(f"[v10.2] sonar must keep os-driver inactive: {payload}")

if sonar.get("status") != "ok":
    raise SystemExit(f"[v10.2] AX sonar failed: {sonar}")
if sonar.get("web_area_found") is not True:
    raise SystemExit(f"[v10.2] AXWebArea was not found: {sonar}")
if result.get("window_id_stable") is not True:
    raise SystemExit(f"[v10.2] target window changed during sonar: {result}")
if result.get("url_changed_after_sonar") is not False:
    raise SystemExit(f"[v10.2] read-only sonar changed URL: {result}")
if result.get("ax_mutation_attempted") is not False:
    raise SystemExit(f"[v10.2] sonar attempted AX mutation: {result}")
if result.get("visual_change_detected") is not False:
    raise SystemExit(f"[v10.2] sonar changed visual topology: {result}")
if not isinstance(sonar.get("web_area_attribute_names"), list):
    raise SystemExit(f"[v10.2] missing web area attributes: {sonar}")
if not isinstance(sonar.get("web_area_parameterized_attribute_names"), list):
    raise SystemExit(f"[v10.2] missing web area parameterized attributes: {sonar}")
if not isinstance(sonar.get("sonar_nodes"), list):
    raise SystemExit(f"[v10.2] missing bounded sonar nodes: {sonar}")

print(json.dumps({
    "event": "v102_open_web_ax_attribute_sonar_assertions",
    "web_area_found": True,
    "nearest_scroll_ancestor_found": result.get("nearest_scroll_ancestor_found"),
    "sonar_visited_count": result.get("sonar_visited_count"),
    "scroll_suspect_count": result.get("scroll_suspect_count"),
    "parameterized_suspect_count": result.get("parameterized_suspect_count"),
    "value_suspect_count": result.get("value_suspect_count"),
    "window_id_stable": True,
    "url_changed_after_sonar": False,
    "ax_mutation_attempted": False,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v10.2 open-web AX attribute sonar validation passed"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V91_LOG:-/tmp/genesis_validate_v91_open_web_static_single_shot.log}"

echo "========================================================================"
echo "Genesis v9.1 Open-Web Static Single-Shot Validation"
echo "========================================================================"

./scripts/run_v91_open_web_static_single_shot.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
target = None
maps = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "open_web_shadow_map":
            maps.append(payload)
        elif event == "open_web_static_single_shot_target":
            target = payload
        elif event == "v91_open_web_static_single_shot_summary":
            summary = payload

if len(maps) < 2:
    raise SystemExit(f"[v9.1] expected pre/post maps, got {len(maps)}")
if target is None:
    raise SystemExit("[v9.1] missing selected target event")
if summary is None:
    raise SystemExit("[v9.1] missing static single-shot summary")

for event in maps:
    if event.get("posted") is not False or event.get("os_driver_active") is not False:
        raise SystemExit(f"[v9.1] shadow maps must remain read-only: {event}")

if target.get("posted") is not False or target.get("occlusion_clear") is not True:
    raise SystemExit(f"[v9.1] target selection failed safety checks: {target}")
if target.get("target_kind") != "link-like":
    raise SystemExit(f"[v9.1] validation target must be link-like: {target}")

if summary.get("armed") is not False:
    raise SystemExit(f"[v9.1] validation must remain dry-run: {summary}")
if summary.get("posted") is not False or summary.get("move_posted") is not False or summary.get("click_posted") is not False:
    raise SystemExit(f"[v9.1] dry-run leaked physical posting: {summary}")
if summary.get("url_changed") is not False or summary.get("assert_match") is not True:
    raise SystemExit(f"[v9.1] dry-run URL assertion failed: {summary}")

print(json.dumps({
    "event": "v91_open_web_static_single_shot_assertions",
    "target_id": target.get("target_id"),
    "target_kind": target.get("target_kind"),
    "map_count": len(maps),
    "url_changed": summary.get("url_changed"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.1 open-web static single-shot validation passed"
echo "========================================================================"

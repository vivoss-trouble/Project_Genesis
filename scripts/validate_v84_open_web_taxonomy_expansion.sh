#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V84_LOG:-/tmp/genesis_validate_v84_open_web_taxonomy.log}"

echo "========================================================================"
echo "Genesis v8.4 Open-Web Taxonomy Expansion Validation"
echo "========================================================================"

./scripts/validate_v81_open_web_shadow_map.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
event = None
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "open_web_shadow_map":
            event = payload

if event is None:
    raise SystemExit("[v8.4] missing shadow map event")

targets = event.get("targets") or []
heading = [target for target in targets if target.get("control_kind") == "heading"]
code = [target for target in targets if target.get("control_kind") == "code-block"]
if not heading:
    raise SystemExit(f"[v8.4] expected at least one heading target: {event}")
if not code:
    raise SystemExit(f"[v8.4] expected at least one code-block target: {event}")
if event.get("posted") is not False or event.get("os_driver_active") is not False:
    raise SystemExit(f"[v8.4] taxonomy validation must stay read-only: {event}")

print(json.dumps({
    "event": "v84_open_web_taxonomy_expansion_assertions",
    "heading_count": len(heading),
    "code_block_count": len(code),
    "posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v8.4 open-web taxonomy expansion validation passed"
echo "========================================================================"

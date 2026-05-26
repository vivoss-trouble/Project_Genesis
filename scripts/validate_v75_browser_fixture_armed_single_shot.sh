#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V75_LOG:-/tmp/genesis_validate_v75_browser_fixture_single_shot.log}"

echo "========================================================================"
echo "Genesis v7.5 Browser Fixture Single-Shot Validation"
echo "========================================================================"

./scripts/run_v75_browser_fixture_armed_single_shot.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
map_events = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        if payload.get("event") == "browser_fixture_readonly_map":
            map_events.append(payload)
        elif payload.get("event") == "v75_browser_fixture_single_shot_summary":
            summary = payload

if len(map_events) < 2:
    raise SystemExit(f"[v7.5] expected pre/post map evidence, got {len(map_events)}")
if summary is None:
    raise SystemExit("[v7.5] missing single-shot summary")
if summary.get("armed") is not False:
    raise SystemExit(f"[v7.5] validation must remain dry-run: {summary}")
if summary.get("posted") is not False or summary.get("move_posted") is not False or summary.get("click_posted") is not False:
    raise SystemExit(f"[v7.5] dry-run must not post: {summary}")
if summary.get("assert_match") is not False:
    raise SystemExit(f"[v7.5] dry-run must not mutate fixture: {summary}")

print(json.dumps({
    "event": "v75_browser_fixture_single_shot_assertions",
    "map_count": len(map_events),
    "assert_match": summary.get("assert_match"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.5 Browser fixture single-shot validation passed"
echo "========================================================================"

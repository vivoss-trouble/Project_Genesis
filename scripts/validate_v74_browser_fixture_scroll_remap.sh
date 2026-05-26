#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V74_LOG:-/tmp/genesis_validate_v74_browser_fixture_scroll_remap.log}"

echo "========================================================================"
echo "Genesis v7.4 Browser Fixture Scroll-Remap Validation"
echo "========================================================================"

./scripts/run_v74_browser_fixture_scroll_remap.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

log_path = sys.argv[1]
summary = None
pre = None
post = None
scroll = None
map_count = 0

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "browser_fixture_readonly_map":
            map_count += 1
            if payload.get("posted") is not False:
                raise SystemExit(f"[v7.4] map posted unexpectedly: {payload}")
        elif event == "browser_fixture_pre_scroll_tracked_target":
            pre = payload
        elif event == "browser_fixture_post_scroll_tracked_target":
            post = payload
        elif event == "os_driver_scroll":
            scroll = payload.get("scroll")
        elif event == "v74_browser_fixture_scroll_remap_summary":
            summary = payload

if map_count < 2:
    raise SystemExit(f"[v7.4] expected pre and post maps, got {map_count}")
if pre is None or post is None:
    raise SystemExit("[v7.4] missing tracked target before/after evidence")
if scroll is None:
    raise SystemExit("[v7.4] missing os-driver scroll event")
if summary is None:
    raise SystemExit("[v7.4] missing scroll-remap summary")
if scroll.get("armed") is not False or (scroll.get("receipt") or {}).get("posted") is not False:
    raise SystemExit(f"[v7.4] scroll must remain unposted: {scroll}")
if summary.get("posted") is not False or summary.get("scroll_posted") is not False:
    raise SystemExit(f"[v7.4] summary violated projection-only mode: {summary}")
if abs(summary.get("observed_global_y_delta", 0)) < 20:
    raise SystemExit(f"[v7.4] remap delta too small: {summary}")

print(json.dumps({
    "event": "v74_browser_fixture_scroll_remap_assertions",
    "tracked_target_id": summary.get("tracked_target_id"),
    "observed_global_y_delta": summary.get("observed_global_y_delta"),
    "map_count": map_count,
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v7.4 Browser fixture scroll-remap validation passed"
echo "========================================================================"

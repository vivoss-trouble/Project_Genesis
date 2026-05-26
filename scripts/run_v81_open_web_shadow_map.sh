#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MAPPER_BIN="${GENESIS_V81_MAPPER_BIN:-/tmp/genesis_v81_open_web_shadow_map}"
TARGET_URL="${GENESIS_V81_URL:-file://$ROOT_DIR/fixtures/v8/open_web_shadow_sample.html}"
BROWSER_APP="${GENESIS_V81_BROWSER_APP:-Safari}"
DEBUG_PNG="${GENESIS_V81_DEBUG_PNG:-/tmp/genesis_v81_shadow_map.png}"

open_target_url() {
    local url="$1"
    if [[ "$BROWSER_APP" == "Safari" || "$BROWSER_APP" == "Safari浏览器" ]]; then
        osascript - "$url" <<'OSA'
on run argv
    set targetUrl to item 1 of argv
    tell application "Safari"
        activate
        open location targetUrl
    end tell
end run
OSA
    else
        open -a "$BROWSER_APP" "$url" || open "$url"
    fi
}

echo "========================================================================"
echo "Genesis v8.1 Open-Web Shadow Mapping"
echo "========================================================================"
echo "[v8.1] URL: $TARGET_URL"
echo "[v8.1] Debug overlay: $DEBUG_PNG"

swiftc scripts/open_web_shadow_map.swift -o "$MAPPER_BIN"
open_target_url "$TARGET_URL"
sleep "${GENESIS_V81_BROWSER_SETTLE_SEC:-1.5}"

GENESIS_V81_DEBUG_PNG="$DEBUG_PNG" "$MAPPER_BIN"

echo "========================================================================"
echo "Genesis v8.1 open-web shadow mapping complete"
echo "========================================================================"

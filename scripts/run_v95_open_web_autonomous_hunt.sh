#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V95_OUTPUT_DIR:-/tmp/genesis_v95_open_web_autonomous_hunt}"
LOG_PATH="$OUTPUT_DIR/hunter.log"
TARGET_URL="${GENESIS_V95_URL:-https://doc.rust-lang.org/book/}"
TARGET_KIND="${GENESIS_V95_TARGET_KIND:-link-like}"
TARGET_STRATEGY="${GENESIS_V95_TARGET_STRATEGY:-bottommost}"
ARMED_TOKEN="GENESIS_V95_ARMED_OPEN_WEB_AUTONOMOUS_HUNT"
AUTO_FIRE_TOKEN="GENESIS_V95_AUTO_FIRE_HUNT"

echo "========================================================================"
echo "Genesis v9.5 Open-Web Autonomous Hunt Gate"
echo "========================================================================"
echo "[v9.5] URL: $TARGET_URL"
echo "[v9.5] Target kind: $TARGET_KIND"
echo "[v9.5] Target strategy: $TARGET_STRATEGY"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

ARMED=false
if [[ "${GENESIS_V95_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V95_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v9.5] Armed autonomous hunt requires GENESIS_V95_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v9.5] ARMED autonomous hunt requested. Delegating to bounded v9.4 hunter."
    GENESIS_V94_ARMED_CONFIRM=GENESIS_V94_ARMED_OPEN_WEB_HUNTER \
    GENESIS_V94_AUTO_FIRE_CONFIRM=GENESIS_V94_AUTO_FIRE_HUNTER_SHOT \
    GENESIS_V94_URL="$TARGET_URL" \
    GENESIS_V94_TARGET_KIND="$TARGET_KIND" \
    GENESIS_V94_TARGET_STRATEGY="$TARGET_STRATEGY" \
    GENESIS_V94_OUTPUT_DIR="$OUTPUT_DIR/v94_hunter" \
        ./scripts/run_v94_open_web_hunter_controller.sh | tee "$LOG_PATH"
else
    echo "[v9.5] Dry-run mode. Delegating to v9.4 hunter without physical posting."
    GENESIS_V94_URL="$TARGET_URL" \
    GENESIS_V94_TARGET_KIND="$TARGET_KIND" \
    GENESIS_V94_TARGET_STRATEGY="$TARGET_STRATEGY" \
    GENESIS_V94_OUTPUT_DIR="$OUTPUT_DIR/v94_hunter" \
        ./scripts/run_v94_open_web_hunter_controller.sh | tee "$LOG_PATH"
fi

python3 - "$LOG_PATH" "$ARMED" <<'PY'
import json
import sys

log_path, armed_raw = sys.argv[1:3]
armed = armed_raw == "true"
hunter_summary = None
scroll_count = 0
plans = []

with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        payload = json.loads(raw)
        event = payload.get("event")
        if event == "open_web_hunter_step_plan":
            plans.append(payload)
        elif event == "os_driver_scroll":
            scroll_count += 1
        elif event == "v94_open_web_hunter_controller_summary":
            hunter_summary = payload

if hunter_summary is None:
    raise SystemExit("[v9.5] missing delegated v9.4 hunter summary")

if armed:
    if hunter_summary.get("armed") is not True:
        raise SystemExit(f"[v9.5] delegated hunter was not armed: {hunter_summary}")
    if hunter_summary.get("fired") is not True or hunter_summary.get("stop_reason") != "fired":
        raise SystemExit(f"[v9.5] autonomous hunt did not fire: {hunter_summary}")
    if hunter_summary.get("scroll_posted") is not True:
        raise SystemExit(f"[v9.5] autonomous hunt did not post maneuver scroll: {hunter_summary}")
    if hunter_summary.get("click_posted") is not True:
        raise SystemExit(f"[v9.5] autonomous hunt did not post final click: {hunter_summary}")
    if hunter_summary.get("url_changed") is not True:
        raise SystemExit(f"[v9.5] autonomous hunt did not produce URL transition: {hunter_summary}")
else:
    if hunter_summary.get("armed") is not False:
        raise SystemExit(f"[v9.5] dry-run delegated hunter became armed: {hunter_summary}")
    if hunter_summary.get("posted") is not False:
        raise SystemExit(f"[v9.5] dry-run leaked physical posting: {hunter_summary}")
    if hunter_summary.get("url_changed") is not False:
        raise SystemExit(f"[v9.5] dry-run changed URL: {hunter_summary}")
    if hunter_summary.get("stop_reason") != "dry_run_projection_stop":
        raise SystemExit(f"[v9.5] dry-run did not stop at projection boundary: {hunter_summary}")

print(json.dumps({
    "event": "v95_open_web_autonomous_hunt_summary",
    "armed": armed,
    "hunter_stop_reason": hunter_summary.get("stop_reason"),
    "hunter_fired": hunter_summary.get("fired"),
    "scroll_count": hunter_summary.get("scroll_count"),
    "scroll_posted": hunter_summary.get("scroll_posted"),
    "click_posted": hunter_summary.get("click_posted"),
    "target_id": hunter_summary.get("target_id"),
    "url_changed": hunter_summary.get("url_changed"),
    "assert_match": hunter_summary.get("url_changed") if armed else not hunter_summary.get("url_changed"),
    "posted": hunter_summary.get("posted"),
    "plan_count": len(plans),
    "receipt_scroll_count": scroll_count,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v9.5 open-web autonomous hunt gate complete"
echo "========================================================================"

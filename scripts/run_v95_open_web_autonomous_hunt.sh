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
    set +e
    GENESIS_V94_ARMED_CONFIRM=GENESIS_V94_ARMED_OPEN_WEB_HUNTER \
    GENESIS_V94_AUTO_FIRE_CONFIRM=GENESIS_V94_AUTO_FIRE_HUNTER_SHOT \
    GENESIS_V94_URL="$TARGET_URL" \
    GENESIS_V94_TARGET_KIND="$TARGET_KIND" \
    GENESIS_V94_TARGET_STRATEGY="$TARGET_STRATEGY" \
    GENESIS_V94_OUTPUT_DIR="$OUTPUT_DIR/v94_hunter" \
        ./scripts/run_v94_open_web_hunter_controller.sh | tee "$LOG_PATH"
    HUNTER_STATUS="${PIPESTATUS[0]}"
    set -e
else
    echo "[v9.5] Dry-run mode. Delegating to v9.4 hunter without physical posting."
    set +e
    GENESIS_V94_URL="$TARGET_URL" \
    GENESIS_V94_TARGET_KIND="$TARGET_KIND" \
    GENESIS_V94_TARGET_STRATEGY="$TARGET_STRATEGY" \
    GENESIS_V94_OUTPUT_DIR="$OUTPUT_DIR/v94_hunter" \
        ./scripts/run_v94_open_web_hunter_controller.sh | tee "$LOG_PATH"
    HUNTER_STATUS="${PIPESTATUS[0]}"
    set -e
fi

python3 - "$LOG_PATH" "$ARMED" "$HUNTER_STATUS" <<'PY'
import json
import sys

log_path, armed_raw, hunter_status_raw = sys.argv[1:4]
armed = armed_raw == "true"
hunter_status = int(hunter_status_raw)
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

assert_match = False
failure_kind = None
if armed:
    assert_match = (
        hunter_status == 0
        and hunter_summary.get("armed") is True
        and hunter_summary.get("fired") is True
        and hunter_summary.get("stop_reason") == "fired"
        and hunter_summary.get("scroll_posted") is True
        and hunter_summary.get("click_posted") is True
        and hunter_summary.get("url_changed") is True
    )
    if not assert_match:
        failure_kind = hunter_summary.get("stop_reason") or "delegated_hunter_failed"
else:
    assert_match = (
        hunter_status == 0
        and hunter_summary.get("armed") is False
        and hunter_summary.get("posted") is False
        and hunter_summary.get("url_changed") is False
        and hunter_summary.get("stop_reason") == "dry_run_projection_stop"
    )
    if not assert_match:
        failure_kind = hunter_summary.get("stop_reason") or "dry_run_contract_failed"

print(json.dumps({
    "event": "v95_open_web_autonomous_hunt_summary",
    "armed": armed,
    "hunter_exit_status": hunter_status,
    "hunter_stop_reason": hunter_summary.get("stop_reason"),
    "hunter_fired": hunter_summary.get("fired"),
    "scroll_count": hunter_summary.get("scroll_count"),
    "scroll_posted": hunter_summary.get("scroll_posted"),
    "click_posted": hunter_summary.get("click_posted"),
    "target_id": hunter_summary.get("target_id"),
    "url_changed": hunter_summary.get("url_changed"),
    "assert_match": assert_match,
    "failure_kind": failure_kind,
    "posted": hunter_summary.get("posted"),
    "scroll_no_progress_count": hunter_summary.get("scroll_no_progress_count"),
    "last_scroll_progress_delta_y": hunter_summary.get("last_scroll_progress_delta_y"),
    "plan_count": len(plans),
    "receipt_scroll_count": scroll_count,
}, sort_keys=True))

if not assert_match:
    raise SystemExit(1)
PY

echo "========================================================================"
echo "Genesis v9.5 open-web autonomous hunt gate complete"
echo "========================================================================"

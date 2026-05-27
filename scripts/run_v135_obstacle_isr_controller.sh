#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V135_OUTPUT_DIR:-/tmp/genesis_v135_obstacle_isr_controller}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
CHILD_LOG="$OUTPUT_DIR/v130_child.jsonl"
CHILD_OUTPUT_DIR="$OUTPUT_DIR/v130_child"
STEP_ID="${GENESIS_V135_STEP_ID:-step-0-next-chapter}"
TARGET_TITLE="${GENESIS_V135_TARGET_TITLE:-Next chapter}"
CURRENT_URL="${GENESIS_V135_CURRENT_URL:-file://$ROOT_DIR/fixtures/v13/obstacle_clearance_fixture.html}"
ARMED_TOKEN="GENESIS_V135_ARMED_ISR_CONTROLLER"
AUTO_FIRE_TOKEN="GENESIS_V135_AUTO_FIRE_ISR_CONTROLLER"

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
}

echo "========================================================================"
echo "Genesis v13.5 Obstacle ISR Controller"
echo "========================================================================"
echo "[v13.5] Step: $STEP_ID"
echo "[v13.5] Target: $TARGET_TITLE"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V135_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V135_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v13.5] Armed ISR requires GENESIS_V135_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v13.5] ARMED ISR requested. It delegates physical clearance to v13.0 only."
else
    echo "[v13.5] Dry-run mode. It freezes context and stops at the ISR projection boundary."
fi

CHILD_ENV=(
    "GENESIS_V130_OUTPUT_DIR=$CHILD_OUTPUT_DIR"
)

if [[ "$ARMED" == true ]]; then
    CHILD_ENV+=(
        "GENESIS_V130_ARMED_CONFIRM=GENESIS_V130_ARMED_OBSTACLE_CLEARANCE"
        "GENESIS_V130_AUTO_FIRE_CONFIRM=GENESIS_V130_AUTO_FIRE_OBSTACLE_CLEARANCE"
    )
fi

set +e
env "${CHILD_ENV[@]}" ./scripts/run_v130_obstacle_clearance_probe.sh | tee "$CHILD_LOG"
CHILD_STATUS=${PIPESTATUS[0]}
set -e

python3 - "$CHILD_LOG" "$RESULTS_LOG" "$STEP_ID" "$TARGET_TITLE" "$CURRENT_URL" "$ARMED" "$CHILD_STATUS" <<'PY'
import json
import sys

child_log, results_log, step_id, target_title, current_url, armed_raw, child_status_raw = sys.argv[1:8]
armed = armed_raw == "true"
child_status = int(child_status_raw)

events = []
with open(child_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

pre = next((event for event in events if event.get("event") == "v130_obstacle_clearance_probe"), None)
summary = next((event for event in events if event.get("event") == "v130_obstacle_clearance_summary"), None)
post_probes = [event for event in events if event.get("event") == "v130_obstacle_clearance_probe"]
post = post_probes[-1] if len(post_probes) > 1 else None

def append(payload):
    line = json.dumps(payload, sort_keys=True)
    print(line)
    with open(results_log, "a", encoding="utf-8") as output:
        output.write(line + "\n")

if pre is None:
    append({
        "event": "v135_isr_summary",
        "armed": armed,
        "isr_complete": False,
        "resume_allowed": False,
        "stop_reason": "child_probe_missing",
        "child_status": child_status,
        "posted": False,
    })
    raise SystemExit(1)

interrupt_requested = pre.get("target_found") is True and pre.get("occlusion_clear") is False
append({
    "event": "v135_isr_interrupt",
    "step_id": step_id,
    "target_title": target_title,
    "current_url": current_url,
    "interrupt_requested": "obstacle_clearance" if interrupt_requested else None,
    "target_found": pre.get("target_found"),
    "occlusion_clear": pre.get("occlusion_clear"),
    "occluder_found": pre.get("occluder_found"),
    "main_loop_frozen": interrupt_requested,
    "posted": False,
})

append({
    "event": "v135_state_freeze",
    "step_id": step_id,
    "target_title": target_title,
    "current_url": current_url,
    "target_point": pre.get("target_point"),
    "occluder_frame": pre.get("occluder_frame"),
    "candidate_count": pre.get("candidate_count"),
    "legal_candidate_count": pre.get("legal_candidate_count"),
    "rejected_candidate_count": pre.get("rejected_candidate_count"),
    "clearance_point": pre.get("clearance_point"),
    "posted": False,
})

child_success_shape = False
if summary:
    child_success_shape = (
        summary.get("click_posted") is True
        and summary.get("target_clear_after") is True
        and summary.get("stop_reason") == "complete"
    )
    append({
        "event": "v135_child_clearance_summary",
        "step_id": step_id,
        "armed": armed,
        "child_status": child_status,
        "child_stop_reason": summary.get("stop_reason"),
        "child_clearance_resolved": summary.get("clearance_resolved"),
        "child_click_posted": summary.get("click_posted"),
        "child_target_clear_after": summary.get("target_clear_after"),
        "child_candidate_count": summary.get("candidate_count"),
        "child_legal_candidate_count": summary.get("legal_candidate_count"),
        "child_rejected_candidate_count": summary.get("rejected_candidate_count"),
        "posted": bool(summary.get("posted")),
    })

if child_status != 0:
    stop_reason = "obstacle_unresolved"
elif not interrupt_requested:
    stop_reason = "no_interrupt_requested"
elif not armed:
    stop_reason = "dry_run_isr_projection_stop"
elif child_success_shape:
    stop_reason = "complete"
else:
    stop_reason = "isr_remap_failed"

resume_allowed = armed and child_success_shape and post is not None and post.get("occlusion_clear") is True
append({
    "event": "v135_isr_summary",
    "step_id": step_id,
    "armed": armed,
    "interrupt_requested": interrupt_requested,
    "main_loop_frozen": interrupt_requested,
    "child_status": child_status,
    "isr_complete": resume_allowed,
    "resume_allowed": resume_allowed,
    "requires_fresh_v12_remap": resume_allowed,
    "click_posted": bool(summary and summary.get("click_posted")),
    "target_clear_after": bool(summary and summary.get("target_clear_after")),
    "stop_reason": stop_reason,
    "posted": armed and bool(summary and summary.get("posted")),
})

if child_status != 0:
    raise SystemExit(child_status)
if armed and not resume_allowed:
    raise SystemExit(2)
PY

echo "========================================================================"
echo "Genesis v13.5 obstacle ISR controller complete"
echo "========================================================================"

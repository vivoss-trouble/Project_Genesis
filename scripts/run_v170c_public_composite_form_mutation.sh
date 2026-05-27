#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V170C_OUTPUT_DIR:-/tmp/genesis_v170c_public_composite_form_mutation}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
ARMED_TOKEN="GENESIS_V170C_ARMED_PUBLIC_COMPOSITE_FORM"
AUTO_FIRE_TOKEN="GENESIS_V170C_AUTO_FIRE_PUBLIC_COMPOSITE_FORM"

mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

echo "========================================================================"
echo "Genesis v17.0c Public Composite Form Mutation"
echo "========================================================================"
echo "[v17.0c] Flow: TextField -> Checkbox -> Combobox"

armed=false
if [[ "${GENESIS_V170C_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    armed=true
    if [[ "${GENESIS_V170C_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v17.0c] Armed composite mutation requires GENESIS_V170C_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 2
    fi
    echo "[v17.0c] ARMED requested. It will run three public GUI mutations serially."
else
    echo "[v17.0c] Dry-run mode. It will run each primitive to its projection boundary."
fi

run_step() {
    local step_id="$1"
    local command_name="$2"
    local event_name="$3"
    local log_path="$OUTPUT_DIR/${step_id}.jsonl"
    shift 3

    echo "------------------------------------------------------------------------"
    echo "[v17.0c] Step $step_id: $command_name"
    echo "------------------------------------------------------------------------"
    : > "$log_path"
    "$@" | tee "$log_path" | tee -a "$RESULTS_LOG"

    python3 - "$log_path" "$event_name" "$armed" "$step_id" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

log_path, event_name, armed_raw, step_id = sys.argv[1:5]
armed = armed_raw == "true"
events = []
with open(log_path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

matches = [
    event for event in events
    if event.get("event") == event_name and event.get("armed") is armed
]
if not matches:
    raise SystemExit(f"missing summary for {step_id}: {event_name}")

summary = matches[-1]
payload = {
    "event": "v170c_composite_step_receipt",
    "step_id": step_id,
    "source_event": event_name,
    "armed": armed,
    "summary": summary,
}
print(json.dumps(payload, sort_keys=True))
PY
}

if $armed; then
    run_step \
        "step-0-textfield" \
        "v16.0 public controlled business mutation" \
        "v160_public_controlled_business_mutation_summary" \
        env \
            GENESIS_V160_ARMED_CONFIRM=GENESIS_V160_ARMED_PUBLIC_BUSINESS_MUTATION \
            GENESIS_V160_AUTO_FIRE_CONFIRM=GENESIS_V160_AUTO_FIRE_PUBLIC_BUSINESS_MUTATION \
            ./scripts/run_v160_public_controlled_business_mutation.sh

    run_step \
        "step-1-checkbox" \
        "v17.0a public binary state collapse" \
        "v170a_public_binary_state_collapse_summary" \
        env \
            GENESIS_V170A_ARMED_CONFIRM=GENESIS_V170A_ARMED_PUBLIC_BINARY_STATE \
            GENESIS_V170A_AUTO_FIRE_CONFIRM=GENESIS_V170A_AUTO_FIRE_PUBLIC_BINARY_STATE \
            ./scripts/run_v170a_public_binary_state_collapse.sh

    run_step \
        "step-2-combobox" \
        "v17.0b public combobox state collapse" \
        "v170b_public_combobox_state_collapse_summary" \
        env \
            GENESIS_V170B_ARMED_CONFIRM=GENESIS_V170B_ARMED_PUBLIC_COMBOBOX_STATE \
            GENESIS_V170B_AUTO_FIRE_CONFIRM=GENESIS_V170B_AUTO_FIRE_PUBLIC_COMBOBOX_STATE \
            ./scripts/run_v170b_public_combobox_state_collapse.sh
else
    run_step \
        "step-0-textfield" \
        "v16.0 public controlled business mutation" \
        "v160_public_controlled_business_mutation_summary" \
        ./scripts/run_v160_public_controlled_business_mutation.sh

    run_step \
        "step-1-checkbox" \
        "v17.0a public binary state collapse" \
        "v170a_public_binary_state_collapse_summary" \
        ./scripts/run_v170a_public_binary_state_collapse.sh

    run_step \
        "step-2-combobox" \
        "v17.0b public combobox state collapse" \
        "v170b_public_combobox_state_collapse_summary" \
        ./scripts/run_v170b_public_combobox_state_collapse.sh
fi

python3 - "$RESULTS_LOG" "$armed" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

log_path, armed_raw = sys.argv[1:3]
armed = armed_raw == "true"
events = []
with open(log_path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

receipts = [
    event for event in events
    if event.get("event") == "v170c_composite_step_receipt"
    and event.get("armed") is armed
]
by_step = {event["step_id"]: event["summary"] for event in receipts}
required = ["step-0-textfield", "step-1-checkbox", "step-2-combobox"]
missing = [step for step in required if step not in by_step]
if missing:
    raise SystemExit(f"missing composite step receipts: {missing}")

textfield = by_step["step-0-textfield"]
checkbox = by_step["step-1-checkbox"]
combobox = by_step["step-2-combobox"]

if armed:
    textfield_asserted = (
        textfield.get("field_ready") is True
        and textfield.get("commit_click_posted") is True
        and textfield.get("business_state_asserted") is True
        and textfield.get("url_unchanged") is True
    )
    checkbox_asserted = (
        checkbox.get("mutation_posted") is True
        and checkbox.get("fresh_remap_done") is True
        and checkbox.get("state_changed_once") is True
        and checkbox.get("business_state_asserted") is True
        and checkbox.get("url_unchanged") is True
    )
    combobox_asserted = (
        combobox.get("combo_click_posted") is True
        and combobox.get("option_click_posted") is True
        and combobox.get("popup_expanded_seen") is True
        and combobox.get("popup_collapsed_after") is True
        and combobox.get("business_state_asserted") is True
        and combobox.get("url_unchanged") is True
    )
    url_unchanged_all = all(
        step.get("url_unchanged") is True
        for step in (textfield, checkbox, combobox)
    )
    business_state_asserted_all = (
        textfield_asserted and checkbox_asserted and combobox_asserted
    )
    sequence_complete = business_state_asserted_all and url_unchanged_all
    stop_reason = "complete" if sequence_complete else "composite_assertion_failed"
else:
    textfield_asserted = False
    checkbox_asserted = False
    combobox_asserted = False
    url_unchanged_all = None
    business_state_asserted_all = False
    sequence_complete = False
    stop_reason = "dry_run_composite_projection_stop"

summary = {
    "event": "v170c_public_composite_form_mutation_summary",
    "armed": armed,
    "posted": armed,
    "step_count": len(required),
    "step_order": required,
    "textfield_state_asserted": textfield_asserted,
    "checkbox_state_asserted": checkbox_asserted,
    "combobox_state_asserted": combobox_asserted,
    "url_unchanged_all": url_unchanged_all,
    "business_state_asserted_all": business_state_asserted_all,
    "state_pollution_detected": False if (not armed or sequence_complete) else True,
    "sequence_complete": sequence_complete,
    "stop_reason": stop_reason,
    "textfield_transport": textfield.get("field_transport"),
    "checkbox_pre_state": checkbox.get("pre_state"),
    "checkbox_post_state": checkbox.get("post_state"),
    "combobox_pre_value": combobox.get("pre_value"),
    "combobox_post_value": combobox.get("post_value"),
}
print(json.dumps(summary, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v17.0c public composite form mutation complete"
echo "========================================================================"

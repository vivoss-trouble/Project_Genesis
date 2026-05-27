#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUTPUT_DIR="${GENESIS_V140_OUTPUT_DIR:-/tmp/genesis_v140_iframe_obstacle_probe}"
RESULTS_LOG="$OUTPUT_DIR/results.jsonl"
SAME_LOG="$OUTPUT_DIR/same_origin_child.jsonl"
SAME_OUTPUT_DIR="$OUTPUT_DIR/same_origin_child"
SANDBOX_LOG="$OUTPUT_DIR/sandbox_probe.jsonl"
AX_BIN="$OUTPUT_DIR/ax_obstacle_clearance_probe"
BROWSER_APP="${GENESIS_V140_BROWSER_APP:-Safari}"
SAME_FIXTURE="$ROOT_DIR/fixtures/v14/iframe_host_same_origin.html"
SANDBOX_FIXTURE="$ROOT_DIR/fixtures/v14/iframe_host_sandbox.html"
SAME_TITLE="Genesis v14.0 Same-Origin Iframe Fixture"
SANDBOX_TITLE="Genesis v14.0 Sandbox Iframe Fixture"
ARMED_TOKEN="GENESIS_V140_ARMED_IFRAME_OBSTACLE"
AUTO_FIRE_TOKEN="GENESIS_V140_AUTO_FIRE_IFRAME_OBSTACLE"

emit() {
    local payload="$1"
    echo "$payload" | tee -a "$RESULTS_LOG"
}

file_uri() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve().as_uri())
PY
}

open_fixture_url() {
    local url="$1"
    open -a "$BROWSER_APP" "$url" || open "$url"
}

run_sandbox_probe() {
    GENESIS_V130_BROWSER_APP="$BROWSER_APP" \
    GENESIS_V130_WINDOW_TITLE="$SANDBOX_TITLE" \
        "$AX_BIN"
}

wait_for_sandbox_probe() {
    local last_payload=""
    for _ in $(seq 1 40); do
        set +e
        last_payload="$(run_sandbox_probe 2>/dev/null)"
        local status=$?
        set -e
        if [[ $status -eq 0 ]] && python3 - "$last_payload" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if payload.get("status") == "ok" and payload.get("target_found") is True:
    raise SystemExit(0)
raise SystemExit(1)
PY
        then
            echo "$last_payload"
            return 0
        fi
        sleep 0.25
    done
    echo "${last_payload:-{\"event\":\"v130_obstacle_clearance_probe\",\"status\":\"error\",\"error\":\"sandbox iframe fixture did not become ready\",\"posted\":false,\"physical_input_posted\":false,\"ax_mutation_attempted\":false}}"
    return 1
}

echo "========================================================================"
echo "Genesis v14.0 Iframe Obstacle Probe"
echo "========================================================================"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
: > "$RESULTS_LOG"

ARMED=false
if [[ "${GENESIS_V140_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V140_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v14.0] Armed iframe probe requires GENESIS_V140_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v14.0] ARMED same-origin iframe branch requested. Sandbox branch remains read-only."
else
    echo "[v14.0] Dry-run mode. Both iframe branches remain read-only."
fi

SAME_ENV=(
    "GENESIS_V130_FIXTURE_PATH=$SAME_FIXTURE"
    "GENESIS_V130_WINDOW_TITLE=$SAME_TITLE"
    "GENESIS_V130_OUTPUT_DIR=$SAME_OUTPUT_DIR"
)

if [[ "$ARMED" == true ]]; then
    SAME_ENV+=(
        "GENESIS_V130_ARMED_CONFIRM=GENESIS_V130_ARMED_OBSTACLE_CLEARANCE"
        "GENESIS_V130_AUTO_FIRE_CONFIRM=GENESIS_V130_AUTO_FIRE_OBSTACLE_CLEARANCE"
    )
fi

set +e
env "${SAME_ENV[@]}" ./scripts/run_v130_obstacle_clearance_probe.sh | tee "$SAME_LOG"
SAME_STATUS=${PIPESTATUS[0]}
set -e

python3 - "$SAME_LOG" "$RESULTS_LOG" "$ARMED" "$SAME_STATUS" <<'PY'
import json
import sys

same_log, results_log, armed_raw, status_raw = sys.argv[1:5]
armed = armed_raw == "true"
status = int(status_raw)
events = []
with open(same_log, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
probes = [event for event in events if event.get("event") == "v130_obstacle_clearance_probe"]
pre = probes[0] if probes else {}
post = probes[-1] if len(probes) > 1 else None
summary = next((event for event in events if event.get("event") == "v130_obstacle_clearance_summary"), {})
payload = {
    "event": "v140_same_origin_iframe_summary",
    "armed": armed,
    "child_status": status,
    "target_found": pre.get("target_found"),
    "occluder_kind": pre.get("occluder_kind"),
    "candidate_count": pre.get("candidate_count"),
    "legal_candidate_count": pre.get("legal_candidate_count"),
    "rejected_candidate_count": pre.get("rejected_candidate_count"),
    "clearance_resolved": pre.get("clearance_resolved"),
    "click_posted": bool(summary.get("click_posted")),
    "target_clear_after": bool(summary.get("target_clear_after")),
    "post_occlusion_clear": None if post is None else post.get("occlusion_clear"),
    "penetration_model_ok": (
        status == 0
        and pre.get("target_found") is True
        and pre.get("occluder_kind") == "modal"
        and pre.get("candidate_count") == 4
        and pre.get("legal_candidate_count") == 1
        and pre.get("rejected_candidate_count") == 3
        and (not armed or summary.get("target_clear_after") is True)
    ),
    "stop_reason": summary.get("stop_reason"),
    "posted": bool(summary.get("posted")),
}
line = json.dumps(payload, sort_keys=True)
print(line)
with open(results_log, "a", encoding="utf-8") as output:
    output.write(line + "\n")
if status != 0:
    raise SystemExit(status)
PY

swiftc scripts/ax_obstacle_clearance_probe.swift -o "$AX_BIN"
open_fixture_url "$(file_uri "$SANDBOX_FIXTURE")"
sleep "${GENESIS_V140_BROWSER_SETTLE_SEC:-1.5}"

set +e
SANDBOX_JSON="$(wait_for_sandbox_probe)"
SANDBOX_STATUS=$?
set -e
echo "$SANDBOX_JSON" | tee "$SANDBOX_LOG" | tee -a "$RESULTS_LOG" >/dev/null

python3 - "$SANDBOX_JSON" "$RESULTS_LOG" "$SANDBOX_STATUS" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
results_log = sys.argv[2]
status = int(sys.argv[3])
summary = {
    "event": "v140_sandbox_iframe_summary",
    "child_status": status,
    "target_found": payload.get("target_found"),
    "occluder_found": payload.get("occluder_found"),
    "occluder_kind": payload.get("occluder_kind"),
    "candidate_count": payload.get("candidate_count"),
    "legal_candidate_count": payload.get("legal_candidate_count"),
    "clearance_resolved": payload.get("clearance_resolved"),
    "stop_reason": payload.get("stop_reason"),
    "sandbox_safe_death": (
        status == 0
        and payload.get("target_found") is True
        and payload.get("occluder_kind") == "iframe"
        and payload.get("candidate_count") == 0
        and payload.get("legal_candidate_count") == 0
        and payload.get("clearance_resolved") is False
        and payload.get("stop_reason") == "iframe_occluder_unresolved"
    ),
    "posted": False,
}
line = json.dumps(summary, sort_keys=True)
print(line)
with open(results_log, "a", encoding="utf-8") as output:
    output.write(line + "\n")
if status != 0:
    raise SystemExit(status)
PY

python3 - "$RESULTS_LOG" "$ARMED" <<'PY' | tee -a "$RESULTS_LOG"
import json
import sys

log_path, armed_raw = sys.argv[1:3]
armed = armed_raw == "true"
events = []
with open(log_path, "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))
same = next(event for event in events if event.get("event") == "v140_same_origin_iframe_summary")
sandbox = next(event for event in events if event.get("event") == "v140_sandbox_iframe_summary")
print(json.dumps({
    "event": "v140_iframe_obstacle_summary",
    "armed": armed,
    "same_origin_penetration_ok": same.get("penetration_model_ok"),
    "same_origin_click_posted": same.get("click_posted"),
    "same_origin_target_clear_after": same.get("target_clear_after"),
    "sandbox_safe_death": sandbox.get("sandbox_safe_death"),
    "sandbox_stop_reason": sandbox.get("stop_reason"),
    "iframe_probe_complete": same.get("penetration_model_ok") is True and sandbox.get("sandbox_safe_death") is True,
    "posted": armed and bool(same.get("posted")),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.0 iframe obstacle probe complete"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_V201_PACK_ROOT:-$ROOT_DIR/evidence_packs}"
RUN_ID="${GENESIS_V201_RUN_ID:-run_$(date -u +%Y%m%dT%H%M%SZ)_$(git rev-parse --short HEAD)_$$}"
PACK_DIR="$PACK_ROOT/$RUN_ID"
JSON_DIR="$PACK_DIR/json"
RAW_DIR="$PACK_DIR/raw"
SCREEN_DIR="$PACK_DIR/screenshots"
WORK_DIR="$PACK_DIR/work"
MANIFEST_PATH="$PACK_DIR/manifest.json"
TARGET_URL="${GENESIS_V201_TARGET_URL:-https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog/}"
WINDOW_TITLE="${GENESIS_V201_WINDOW_TITLE:-Modal Dialog Example}"
URL_DOMAIN_LOCK="${GENESIS_V201_URL_DOMAIN_LOCK:-w3.org/WAI/ARIA/apg/patterns/dialog-modal/examples/dialog}"
SHADOW_BIN="$WORK_DIR/open_web_shadow_map"
ARMED_TOKEN="GENESIS_V201_ARMED_EVIDENCE_PACK"
AUTO_FIRE_TOKEN="GENESIS_V201_AUTO_FIRE_EVIDENCE_PACK"

if [[ -e "$PACK_DIR" ]]; then
    echo "[v20.1] ERROR: evidence pack already exists: $PACK_DIR" >&2
    exit 2
fi

mkdir -p "$JSON_DIR" "$RAW_DIR" "$SCREEN_DIR" "$WORK_DIR"

ARMED=false
if [[ "${GENESIS_V201_ARMED_CONFIRM:-}" == "$ARMED_TOKEN" ]]; then
    ARMED=true
fi

echo "========================================================================"
echo "Genesis v20.1 Immutable Evidence Pack"
echo "========================================================================"
echo "[v20.1] Evidence pack: $PACK_DIR"
echo "[v20.1] URL: $TARGET_URL"
if [[ "$ARMED" == true ]]; then
    if [[ "${GENESIS_V201_AUTO_FIRE_CONFIRM:-}" != "$AUTO_FIRE_TOKEN" ]]; then
        echo "[v20.1] Armed evidence run requires GENESIS_V201_AUTO_FIRE_CONFIRM=$AUTO_FIRE_TOKEN" >&2
        exit 1
    fi
    echo "[v20.1] ARMED evidence run requested."
else
    echo "[v20.1] Dry-run evidence mode."
fi

write_json() {
    local path="$1"
    local payload="$2"
    python3 - "$path" "$payload" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

latest_event() {
    local path="$1"
    local event_name="$2"
    python3 - "$path" "$event_name" <<'PY'
import json
import sys

path, event_name = sys.argv[1:3]
match = None
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        event = json.loads(raw)
        if event.get("event") == event_name:
            match = event
if match is None:
    raise SystemExit(1)
print(json.dumps(match, sort_keys=True))
PY
}

capture_snapshot() {
    local label="$1"
    local png_path="$SCREEN_DIR/${label}.png"
    local json_path="$JSON_DIR/${label}_shadow_map.json"
    local status_path="$JSON_DIR/${label}_screenshot_status.json"
    set +e
    GENESIS_V81_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V81_DEBUG_PNG="$png_path" \
        "$SHADOW_BIN" > "$json_path" 2>"$RAW_DIR/${label}_shadow_map.stderr"
    local status=$?
    set -e
    if [[ $status -eq 0 && -s "$png_path" ]]; then
        write_json "$status_path" "$(python3 - "$label" "$png_path" "$json_path" <<'PY'
import json
import os
import sys
label, png_path, json_path = sys.argv[1:4]
print(json.dumps({
    "event": "v201_screenshot_status",
    "label": label,
    "screenshot_status": "ok",
    "png_path": png_path,
    "json_path": json_path,
    "png_size": os.path.getsize(png_path),
}, sort_keys=True))
PY
)"
    else
        rm -f "$png_path"
        write_json "$status_path" "$(python3 - "$label" "$status" "$RAW_DIR/${label}_shadow_map.stderr" <<'PY'
import json
import pathlib
import sys
label, status, stderr_path = sys.argv[1:4]
stderr = pathlib.Path(stderr_path).read_text(encoding="utf-8", errors="replace") if pathlib.Path(stderr_path).exists() else ""
print(json.dumps({
    "event": "v201_screenshot_status",
    "label": label,
    "screenshot_status": "failed",
    "exit_code": int(status),
    "error": stderr[-2000:],
}, sort_keys=True))
PY
)"
    fi
}

swiftc scripts/open_web_shadow_map.swift -o "$SHADOW_BIN"

capture_snapshot "00_run_start"

V200_OUT="$WORK_DIR/v20"
if [[ "$ARMED" == true ]]; then
    GENESIS_V200_OUTPUT_DIR="$V200_OUT" \
    GENESIS_V200_TARGET_URL="$TARGET_URL" \
    GENESIS_V200_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V200_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
    GENESIS_V200_ARMED_CONFIRM=GENESIS_V200_ARMED_AUTONOMOUS_EXECUTION \
    GENESIS_V200_AUTO_FIRE_CONFIRM=GENESIS_V200_AUTO_FIRE_FROM_PLAN \
        ./scripts/run_v200_autonomous_armed_execution.sh | tee "$RAW_DIR/v20_stdout.log"
else
    GENESIS_V200_OUTPUT_DIR="$V200_OUT" \
    GENESIS_V200_TARGET_URL="$TARGET_URL" \
    GENESIS_V200_WINDOW_TITLE="$WINDOW_TITLE" \
    GENESIS_V200_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
        ./scripts/run_v200_autonomous_armed_execution.sh | tee "$RAW_DIR/v20_stdout.log"
fi

capture_snapshot "90_final_terminal_state"

V200_LOG="$V200_OUT/results.jsonl"
V19_LOG="$V200_OUT/v19_plan/results.jsonl"
V16_LOG="$V200_OUT/v16_exec/results.jsonl"

cp "$V200_LOG" "$RAW_DIR/v20_results.jsonl"
if [[ -f "$V19_LOG" ]]; then cp "$V19_LOG" "$RAW_DIR/v19_plan_results.jsonl"; fi
if [[ -f "$V16_LOG" ]]; then cp "$V16_LOG" "$RAW_DIR/v16_exec_results.jsonl"; fi

PLAN_PAYLOAD="$(latest_event "$V19_LOG" "v190_public_task_plan")"
V200_SUMMARY="$(latest_event "$V200_LOG" "v200_autonomous_execution_summary")"
write_json "$JSON_DIR/00_intent_plan.json" "$PLAN_PAYLOAD"
write_json "$JSON_DIR/99_v20_summary.json" "$V200_SUMMARY"

python3 - "$V200_LOG" "$V16_LOG" "$JSON_DIR" <<'PY'
import json
import pathlib
import sys

v200_log, v16_log, json_dir = sys.argv[1:4]
json_dir = pathlib.Path(json_dir)

def events(path):
    if not pathlib.Path(path).exists():
        return []
    out = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if raw.startswith("{"):
                out.append(json.loads(raw))
    return out

v200_events = events(v200_log)
v16_events = events(v16_log)

step_receipts = [event for event in v200_events if event.get("event") == "v200_execution_step_receipt"]
source_by_step = {
    "step-0-trigger-modal": next((event for event in v16_events if event.get("event") == "v160_w3c_ground_state"), {}),
    "step-1-fill-text-field": next((event for event in v16_events if event.get("event") == "v160_public_form_lock"), {}),
    "step-2-commit-form": next((event for event in v16_events if event.get("event") == "v160_public_business_state_assertion"), {}),
}
driver_events = [event for event in v16_events if event.get("event") in {"os_driver_probe", "os_driver_move", "os_driver_click"}]

for index, receipt in enumerate(step_receipts, start=1):
    step_id = receipt.get("step_id") or f"step-{index}"
    safe_step = step_id.replace("/", "_")
    pre = {
        "event": "v201_step_pre_remap",
        "step_index": index,
        "step_id": step_id,
        "source_event": source_by_step.get(step_id, {}),
        "fresh_remap_done": receipt.get("fresh_remap_done") is True,
        "stale_plan_coordinates_used": receipt.get("stale_plan_coordinates_used") is True,
    }
    (json_dir / f"{index:02d}_{safe_step}_pre_remap.json").write_text(
        json.dumps(pre, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    matching_driver = []
    if step_id == "step-0-trigger-modal":
        matching_driver = []
    elif step_id == "step-1-fill-text-field":
        matching_driver = [event for event in driver_events if event.get("phase") == "public_business_field_focus"]
    elif step_id == "step-2-commit-form":
        matching_driver = [event for event in driver_events if event.get("phase") == "public_business_verify"]
    driver_payload = {
        "event": "v201_step_driver_receipt",
        "step_index": index,
        "step_id": step_id,
        "driver_events": matching_driver,
        "driver_event_count": len(matching_driver),
    }
    (json_dir / f"{index:02d}_{safe_step}_driver_receipt.json").write_text(
        json.dumps(driver_payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    post = {
        "event": "v201_step_post_assert",
        "step_index": index,
        "step_id": step_id,
        "receipt": receipt,
    }
    (json_dir / f"{index:02d}_{safe_step}_post_assert.json").write_text(
        json.dumps(post, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

isr_events = [event for event in v16_events if "isr" in str(event).lower() or event.get("public_obstacle_seen") is True]
(json_dir / "50_isr_intervention_log.json").write_text(
    json.dumps({
        "event": "v201_isr_intervention_log",
        "isr_event_count": len(isr_events),
        "isr_events": isr_events,
    }, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

RESIDUAL_JSON="$JSON_DIR/99_terminal_scan_report.json"
python3 - "$RESIDUAL_JSON" <<'PY'
import json
import pathlib
import subprocess
import sys

path = pathlib.Path(sys.argv[1])
process_scan = subprocess.run(
    ["bash", "-lc", "ps -axo pid=,comm= | rg '(^|/)(genesis-os-driver|ax_v200|ax_v190|ax_v160|ax_w3c|open_web_shadow_map)' || true"],
    text=True,
    capture_output=True,
)
socket_scan = subprocess.run(
    ["bash", "-lc", "ls -l /tmp/genesis_os_driver_v201.sock /tmp/genesis_os_driver_v200.sock /tmp/genesis_os_driver_v160.sock 2>/dev/null || true"],
    text=True,
    capture_output=True,
)
payload = {
    "event": "v201_terminal_scan_report",
    "process_scan": process_scan.stdout.strip().splitlines(),
    "socket_scan": socket_scan.stdout.strip().splitlines(),
    "residual_processes_detected": bool(process_scan.stdout.strip()),
    "residual_sockets_detected": bool(socket_scan.stdout.strip()),
}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$PACK_DIR" "$MANIFEST_PATH" "$ARMED" <<'PY'
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
import sys

pack_dir = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
armed = sys.argv[3] == "true"

files = []
for path in sorted(pack_dir.rglob("*")):
    if not path.is_file() or path == manifest_path:
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    files.append({
        "path": str(path.relative_to(pack_dir)),
        "sha256": digest,
        "bytes": path.stat().st_size,
    })

git_commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
manifest = {
    "event": "v201_evidence_pack_manifest",
    "schema_version": "v20.1",
    "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    "pack_dir": str(pack_dir),
    "armed": armed,
    "git_commit": git_commit,
    "tool_versions": {
        "run_v201": "v20.1",
        "run_v200": "v20.0",
        "planner": "v19.0",
    },
    "append_only_policy": True,
    "json_fatal": True,
    "screenshot_best_effort": True,
    "file_count": len(files),
    "files": files,
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

cat "$MANIFEST_PATH"

echo "========================================================================"
echo "Genesis v20.1 evidence pack complete"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_V210A_PACK_ROOT:-$ROOT_DIR/evidence_packs}"
RUN_ID="${GENESIS_V210A_RUN_ID:-run_v210a_$(date -u +%Y%m%dT%H%M%SZ)_$(git rev-parse --short HEAD)_$$}"
PACK_DIR="$PACK_ROOT/$RUN_ID"
JSON_DIR="$PACK_DIR/json"
RAW_DIR="$PACK_DIR/raw"
SCREEN_DIR="$PACK_DIR/screenshots"
WORK_DIR="$PACK_DIR/work"
MANIFEST_PATH="$PACK_DIR/manifest.json"

TARGET_URL="${GENESIS_V210A_TARGET_URL:-https://www.wikipedia.org/}"
WINDOW_TITLE="${GENESIS_V210A_WINDOW_TITLE:-Wikipedia}"
URL_DOMAIN_LOCK="${GENESIS_V210A_URL_DOMAIN_LOCK:-wikipedia.org}"
POLL_TIMEOUT_MS="${GENESIS_V210A_POLL_TIMEOUT_MS:-3500}"
POLL_INTERVAL_MS="${GENESIS_V210A_POLL_INTERVAL_MS:-250}"
V19_OUT="$WORK_DIR/v19_plan"
SHADOW_BIN="$WORK_DIR/open_web_shadow_map"

if [[ -e "$PACK_DIR" ]]; then
    echo "[v21.0a] ERROR: evidence pack already exists: $PACK_DIR" >&2
    exit 2
fi

mkdir -p "$JSON_DIR" "$RAW_DIR" "$SCREEN_DIR" "$WORK_DIR"

echo "========================================================================"
echo "Genesis v21.0a Deep-Water Readiness Recon"
echo "========================================================================"
echo "[v21.0a] Evidence pack: $PACK_DIR"
echo "[v21.0a] URL: $TARGET_URL"
echo "[v21.0a] Window title needle: $WINDOW_TITLE"
echo "[v21.0a] Domain lock: $URL_DOMAIN_LOCK"
echo "[v21.0a] Zero-kinetic recon: posted=false, os_driver_active=false."

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

latest_event_or_empty() {
    local path="$1"
    local event_name="$2"
    python3 - "$path" "$event_name" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
event_name = sys.argv[2]
match = None
if path.exists():
    with path.open(encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw.startswith("{"):
                continue
            event = json.loads(raw)
            if event.get("event") == event_name:
                match = event
if match is None:
    match = {}
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
    if [[ $status -eq 0 && -s "$json_path" ]]; then
        if [[ -s "$png_path" ]]; then
            write_json "$status_path" "$(python3 - "$label" "$png_path" "$json_path" <<'PY'
import json
import os
import sys

label, png_path, json_path = sys.argv[1:4]
print(json.dumps({
    "event": "v210a_screenshot_status",
    "label": label,
    "screenshot_status": "ok",
    "png_path": png_path,
    "json_path": json_path,
    "png_size": os.path.getsize(png_path),
}, sort_keys=True))
PY
)"
        else
            write_json "$status_path" "$(python3 - "$label" "$json_path" <<'PY'
import json
import sys

label, json_path = sys.argv[1:3]
print(json.dumps({
    "event": "v210a_screenshot_status",
    "label": label,
    "screenshot_status": "json_only",
    "json_path": json_path,
}, sort_keys=True))
PY
)"
        fi
    else
        rm -f "$png_path"
        write_json "$status_path" "$(python3 - "$label" "$status" "$RAW_DIR/${label}_shadow_map.stderr" <<'PY'
import json
import pathlib
import sys

label, status, stderr_path = sys.argv[1:4]
stderr = pathlib.Path(stderr_path).read_text(encoding="utf-8", errors="replace") if pathlib.Path(stderr_path).exists() else ""
print(json.dumps({
    "event": "v210a_screenshot_status",
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

set +e
GENESIS_V190_OUTPUT_DIR="$V19_OUT" \
GENESIS_V190_TARGET_URL="$TARGET_URL" \
GENESIS_V190_WINDOW_TITLE="$WINDOW_TITLE" \
GENESIS_V190_URL_DOMAIN_LOCK="$URL_DOMAIN_LOCK" \
GENESIS_V190_POLL_TIMEOUT_MS="$POLL_TIMEOUT_MS" \
GENESIS_V190_POLL_INTERVAL_MS="$POLL_INTERVAL_MS" \
    ./scripts/run_v190_public_task_planner.sh > >(tee "$RAW_DIR/v19_stdout.log") 2>"$RAW_DIR/v19_stderr.log"
v19_status=$?
set -e

capture_snapshot "90_final_terminal_state"

V19_LOG="$V19_OUT/results.jsonl"
if [[ -f "$V19_LOG" ]]; then
    cp "$V19_LOG" "$RAW_DIR/v19_plan_results.jsonl"
fi

PLAN_PAYLOAD="$(latest_event_or_empty "$V19_LOG" "v190_public_task_plan")"
PLAN_SUMMARY="$(latest_event_or_empty "$V19_LOG" "v190_public_task_planner_summary")"

if [[ "$PLAN_PAYLOAD" == "{}" ]]; then
    PLAN_PAYLOAD="$(python3 - "$TARGET_URL" "$URL_DOMAIN_LOCK" "$v19_status" <<'PY'
import json
import sys

target_url, domain_lock, status = sys.argv[1:4]
print(json.dumps({
    "event": "v190_public_task_plan",
    "status": "error",
    "error": "planner did not emit a usable plan payload",
    "planner_exit_status": int(status),
    "target_url": target_url,
    "domain_lock": domain_lock,
    "domain_locked": domain_lock in target_url,
    "plan_ready": False,
    "safe_to_arm": False,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
}, sort_keys=True))
PY
)"
fi

write_json "$JSON_DIR/00_intent_plan.json" "$PLAN_PAYLOAD"
write_json "$JSON_DIR/01_public_recon_planner_summary.json" "$PLAN_SUMMARY"

SUMMARY_PAYLOAD="$(python3 - "$PLAN_PAYLOAD" "$PLAN_SUMMARY" "$v19_status" <<'PY'
import json
import sys

plan = json.loads(sys.argv[1])
planner_summary = json.loads(sys.argv[2]) if sys.argv[2] != "{}" else {}
v19_status = int(sys.argv[3])
domain_locked = plan.get("domain_locked") is True
plan_ready = plan.get("plan_ready") is True
stop_reason = "plan_ready_read_only_boundary" if plan_ready else "plan_not_ready_read_only_boundary"
if not domain_locked:
    stop_reason = "domain_lock_failed"
elif plan.get("status") != "ok":
    stop_reason = "planner_status_not_ok"
print(json.dumps({
    "event": "v210a_deep_water_recon_summary",
    "armed": False,
    "read_only_recon": True,
    "target_url": plan.get("target_url"),
    "domain_lock": plan.get("domain_lock"),
    "domain_locked": domain_locked,
    "planner_exit_status": v19_status,
    "planner_status": plan.get("status"),
    "plan_ready": plan_ready,
    "safe_to_arm": plan.get("safe_to_arm") is True,
    "target_sequence_count": len(plan.get("target_sequence") or []),
    "control_type_coverage": plan.get("control_type_coverage") or planner_summary.get("control_type_coverage") or [],
    "public_obstacle_seen": plan.get("public_obstacle_seen") is True,
    "stop_reason": stop_reason,
    "posted": False,
    "physical_input_posted": False,
    "os_driver_active": False,
    "evidence_pack_manifest_ok": True,
    "deep_water_recon_complete": True,
}, sort_keys=True))
PY
)"
write_json "$JSON_DIR/99_v20_summary.json" "$SUMMARY_PAYLOAD"

python3 - "$JSON_DIR/99_terminal_scan_report.json" <<'PY'
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
    "event": "v210a_terminal_scan_report",
    "process_scan": process_scan.stdout.strip().splitlines(),
    "socket_scan": socket_scan.stdout.strip().splitlines(),
    "residual_processes_detected": bool(process_scan.stdout.strip()),
    "residual_sockets_detected": bool(socket_scan.stdout.strip()),
}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$PACK_DIR" "$MANIFEST_PATH" <<'PY'
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

pack_dir = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])

def ledger_sort_key(path):
    rel = str(path.relative_to(pack_dir))
    name = path.name
    if rel == "json/00_intent_plan.json":
        return (0, rel)
    if name.startswith("00_run_start"):
        return (1, rel)
    if rel == "json/01_public_recon_planner_summary.json":
        return (2, rel)
    if name.startswith("90_final_terminal_state"):
        return (90, rel)
    if rel == "json/99_terminal_scan_report.json":
        return (99, rel)
    if rel == "json/99_v20_summary.json":
        return (100, rel)
    return (200, rel)

json_files = sorted((path for path in (pack_dir / "json").glob("*.json") if path.is_file()), key=ledger_sort_key)
for order, path in enumerate(json_files, start=1):
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["evidence_schema_version"] = "v20.3-temporal-hardening"
    payload["evidence_write_order"] = order
    payload["sealed_utc_timestamp_ms"] = time.time_ns() // 1_000_000
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")

files = []
for path in sorted(pack_dir.rglob("*")):
    if not path.is_file() or path == manifest_path:
        continue
    files.append({
        "path": str(path.relative_to(pack_dir)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "bytes": path.stat().st_size,
    })

git_commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
manifest = {
    "event": "v210a_evidence_pack_manifest",
    "schema_version": "v20.3",
    "run_profile": "v21.0a-read-only-recon",
    "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    "pack_dir": str(pack_dir),
    "armed": False,
    "read_only_recon": True,
    "git_commit": git_commit,
    "tool_versions": {
        "run_v210a": "v21.0a",
        "planner": "v19.0",
        "replay_verifier": "v20.2",
        "evidence_schema": "v20.3",
    },
    "append_only_policy": True,
    "json_fatal": True,
    "screenshot_best_effort": True,
    "temporal_hardening": {
        "schema_version": "v20.3",
        "sealed_step_timestamps": True,
        "timestamp_field": "sealed_utc_timestamp_ms",
        "order_field": "evidence_write_order",
        "time_source": "ledger_materialization_utc",
    },
    "file_count": len(files),
    "files": files,
}
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

cat "$MANIFEST_PATH"

echo "========================================================================"
echo "Genesis v21.0a deep-water readiness recon complete"
echo "========================================================================"

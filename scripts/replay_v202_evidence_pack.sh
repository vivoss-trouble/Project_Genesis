#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_DIR="${1:-${GENESIS_V202_PACK_DIR:-}}"
REPORT_PATH="${GENESIS_V202_REPORT_PATH:-}"
TIME_TEAR_THRESHOLD_MS="${GENESIS_V202_TIME_TEAR_THRESHOLD_MS:-1000}"

if [[ -z "$PACK_DIR" ]]; then
    echo "usage: $0 /path/to/v20.1/evidence_pack" >&2
    echo "or set GENESIS_V202_PACK_DIR" >&2
    exit 2
fi

echo "========================================================================"
echo "Genesis v20.2 Offline Replay Verifier"
echo "========================================================================"
echo "[v20.2] Evidence pack: $PACK_DIR"
echo "[v20.2] Time tear advisory threshold: ${TIME_TEAR_THRESHOLD_MS}ms"

python3 - "$PACK_DIR" "$TIME_TEAR_THRESHOLD_MS" "$REPORT_PATH" <<'PY'
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import sys

pack = pathlib.Path(sys.argv[1]).resolve()
threshold_ms = float(sys.argv[2])
report_path = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
manifest_path = pack / "manifest.json"
fatal = []
warnings = []

def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fatal.append({
            "code": "JSON_READ_FATAL",
            "path": rel(path),
            "error": str(exc),
        })
        return {}

def rel(path):
    try:
        return str(path.resolve().relative_to(pack))
    except Exception:
        return str(path)

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def parse_dt(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

if not pack.exists():
    raise SystemExit(f"[v20.2] evidence pack not found: {pack}")
if not manifest_path.exists():
    raise SystemExit(f"[v20.2] manifest missing: {manifest_path}")

manifest = load_json(manifest_path)
armed = manifest.get("armed")
schema_ok = manifest.get("schema_version") == "v20.1"
if not schema_ok:
    fatal.append({
        "code": "MANIFEST_SCHEMA_FATAL",
        "expected": "v20.1",
        "actual": manifest.get("schema_version"),
    })

manifest_files = {}
for item in manifest.get("files") or []:
    path = item.get("path")
    if not isinstance(path, str) or not path or path.startswith("/") or ".." in pathlib.PurePosixPath(path).parts:
        fatal.append({"code": "MANIFEST_PATH_FATAL", "path": path})
        continue
    manifest_files[path] = item

actual_files = {}
for path in sorted(pack.rglob("*")):
    if not path.is_file() or path == manifest_path:
        continue
    actual_files[rel(path)] = path

missing_files = sorted(set(manifest_files) - set(actual_files))
extra_files = sorted(set(actual_files) - set(manifest_files))
if missing_files:
    fatal.append({"code": "MISSING_EVIDENCE_FATAL", "paths": missing_files})
if extra_files:
    fatal.append({"code": "UNMANIFESTED_EVIDENCE_FATAL", "paths": extra_files})

tampered_files = []
for path, item in sorted(manifest_files.items()):
    absolute = actual_files.get(path)
    if absolute is None:
        continue
    actual_hash = sha256(absolute)
    actual_size = absolute.stat().st_size
    if actual_hash != item.get("sha256") or actual_size != item.get("bytes"):
        tampered_files.append({
            "path": path,
            "expected_sha256": item.get("sha256"),
            "actual_sha256": actual_hash,
            "expected_bytes": item.get("bytes"),
            "actual_bytes": actual_size,
        })
if tampered_files:
    fatal.append({"code": "TAMPERED_EVIDENCE_FATAL", "files": tampered_files})

required_json = [
    "json/00_intent_plan.json",
    "json/99_v20_summary.json",
    "json/99_terminal_scan_report.json",
]
for path in required_json:
    if path not in manifest_files:
        fatal.append({"code": "REQUIRED_LEDGER_MISSING_FATAL", "path": path})

intent = load_json(pack / "json/00_intent_plan.json") if (pack / "json/00_intent_plan.json").exists() else {}
summary = load_json(pack / "json/99_v20_summary.json") if (pack / "json/99_v20_summary.json").exists() else {}
terminal = load_json(pack / "json/99_terminal_scan_report.json") if (pack / "json/99_terminal_scan_report.json").exists() else {}
isr_log = load_json(pack / "json/50_isr_intervention_log.json") if (pack / "json/50_isr_intervention_log.json").exists() else {}

if terminal.get("residual_sockets_detected") is True:
    fatal.append({"code": "RESIDUAL_SOCKET_FATAL", "terminal_scan": terminal})

step_pattern = re.compile(r"^json/(\d{2})_(.+)_pre_remap\.json$")
steps = []
for path in sorted(manifest_files):
    match = step_pattern.match(path)
    if not match:
        continue
    index = int(match.group(1))
    safe_step = match.group(2)
    step_id = safe_step
    suffix = f"{index:02d}_{safe_step}"
    pre_path = f"json/{suffix}_pre_remap.json"
    driver_path = f"json/{suffix}_driver_receipt.json"
    post_path = f"json/{suffix}_post_assert.json"
    pre = load_json(pack / pre_path)
    driver = load_json(pack / driver_path) if (pack / driver_path).exists() else {}
    post = load_json(pack / post_path) if (pack / post_path).exists() else {}
    step_id = pre.get("step_id") or post.get("step_id") or safe_step
    steps.append({
        "index": index,
        "safe_step": safe_step,
        "step_id": step_id,
        "pre_path": pre_path,
        "driver_path": driver_path,
        "post_path": post_path,
        "pre": pre,
        "driver": driver,
        "post": post,
    })

steps.sort(key=lambda item: item["index"])
indices = [step["index"] for step in steps]
if indices and indices != list(range(1, len(indices) + 1)):
    fatal.append({"code": "STEP_SEQUENCE_FATAL", "indices": indices})

if armed is True:
    if summary.get("armed") is not True:
        fatal.append({"code": "ARMED_SUMMARY_MISMATCH_FATAL", "summary_armed": summary.get("armed")})
    if summary.get("sequence_complete") is not True:
        fatal.append({"code": "ARMED_SEQUENCE_INCOMPLETE_FATAL", "summary": summary})
    if summary.get("fresh_remap_before_each_step") is not True:
        fatal.append({"code": "FRESH_REMAP_CONTRACT_FATAL", "summary": summary})
    if summary.get("stale_plan_coordinates_used") is not False:
        fatal.append({"code": "STALE_COORDINATE_SUMMARY_FATAL", "summary": summary})
    expected_steps = int(summary.get("target_sequence_count") or 0)
    if expected_steps and len(steps) != expected_steps:
        fatal.append({"code": "STEP_COUNT_FATAL", "expected": expected_steps, "actual": len(steps)})
    if not steps:
        fatal.append({"code": "ARMED_STEP_LEDGER_MISSING_FATAL"})
else:
    if summary.get("armed") is not False:
        fatal.append({"code": "DRY_RUN_SUMMARY_MISMATCH_FATAL", "summary_armed": summary.get("armed")})
    if summary.get("stop_reason") != "dry_run_plan_execution_boundary":
        fatal.append({"code": "DRY_RUN_BOUNDARY_FATAL", "summary": summary})

step_reports = []
for step in steps:
    pre = step["pre"]
    driver = step["driver"]
    post = step["post"]
    receipt = post.get("receipt") or {}
    if pre.get("fresh_remap_done") is not True:
        fatal.append({"code": "STEP_PRE_REMAP_FATAL", "step_id": step["step_id"], "path": step["pre_path"]})
    if pre.get("stale_plan_coordinates_used") is not False:
        fatal.append({"code": "STEP_PRE_STALE_COORDINATE_FATAL", "step_id": step["step_id"], "path": step["pre_path"]})
    if receipt.get("fresh_remap_done") is not True:
        fatal.append({"code": "STEP_POST_REMAP_FATAL", "step_id": step["step_id"], "path": step["post_path"]})
    if receipt.get("stale_plan_coordinates_used") is not False:
        fatal.append({"code": "STALE_COORDINATE_VIOLATION", "step_id": step["step_id"], "path": step["post_path"]})
    if armed is True and step["driver_path"] not in manifest_files:
        fatal.append({"code": "DRIVER_RECEIPT_MISSING_FATAL", "step_id": step["step_id"], "path": step["driver_path"]})

    pre_mtime = actual_files.get(step["pre_path"]).stat().st_mtime if actual_files.get(step["pre_path"]) else None
    driver_mtime = actual_files.get(step["driver_path"]).stat().st_mtime if actual_files.get(step["driver_path"]) else None
    post_mtime = actual_files.get(step["post_path"]).stat().st_mtime if actual_files.get(step["post_path"]) else None
    time_deltas = {}
    if pre_mtime is not None and driver_mtime is not None:
        time_deltas["pre_to_driver_ms_mtime_advisory"] = round((driver_mtime - pre_mtime) * 1000, 3)
    if driver_mtime is not None and post_mtime is not None:
        time_deltas["driver_to_post_ms_mtime_advisory"] = round((post_mtime - driver_mtime) * 1000, 3)
    for key, value in time_deltas.items():
        if value > threshold_ms:
            warnings.append({
                "code": "TIME_TEAR_WARNING",
                "step_id": step["step_id"],
                "metric": key,
                "threshold_ms": threshold_ms,
                "value_ms": value,
                "basis": "filesystem_mtime_not_manifest_sealed",
            })

    step_reports.append({
        "step_index": step["index"],
        "step_id": step["step_id"],
        "fresh_remap_done": receipt.get("fresh_remap_done") is True,
        "stale_plan_coordinates_used": receipt.get("stale_plan_coordinates_used") is True,
        "driver_event_count": driver.get("driver_event_count", 0),
        "posted": receipt.get("posted"),
        "physical_input_posted": receipt.get("physical_input_posted"),
        "time_deltas": time_deltas,
    })

sealed_timestamps = []
for path in ["json/00_intent_plan.json", "json/99_v20_summary.json", "json/99_terminal_scan_report.json"]:
    payload = load_json(pack / path) if (pack / path).exists() else {}
    for key in ("created_at_utc", "timestamp_utc", "timestamp"):
        parsed = parse_dt(payload.get(key))
        if parsed is not None:
            sealed_timestamps.append({"path": path, "key": key, "value": payload.get(key)})
if len(sealed_timestamps) < 2:
    warnings.append({
        "code": "SEALED_STEP_TIMESTAMPS_UNAVAILABLE",
        "time_threshold_enforced": False,
        "reason": "v20.1 evidence packs do not seal per-step UTC timestamps; mtime checks are advisory only",
    })

kinetic_delta_ok = True
if armed is True:
    if "raw/v16_exec_results.jsonl" not in manifest_files:
        kinetic_delta_ok = False
        fatal.append({"code": "ARMED_KINETIC_SOURCE_MISSING_FATAL", "path": "raw/v16_exec_results.jsonl"})
    if not any((step["post"].get("receipt") or {}).get("physical_input_posted") is True for step in steps):
        kinetic_delta_ok = False
        fatal.append({"code": "ARMED_PHYSICAL_INPUT_MISSING_FATAL"})
else:
    if "raw/v16_exec_results.jsonl" in manifest_files:
        warnings.append({"code": "DRY_RUN_HAS_V16_TRACE_WARNING", "path": "raw/v16_exec_results.jsonl"})

report = {
    "event": "v202_replay_verdict",
    "status": "failed" if fatal else "ok",
    "pack_dir": str(pack),
    "schema_verified": schema_ok,
    "armed": armed,
    "manifest_file_count": len(manifest_files),
    "actual_file_count": len(actual_files),
    "cryptographic_seal_ok": not missing_files and not extra_files and not tampered_files,
    "arrow_of_time_order_ok": not any(item.get("code") == "STEP_SEQUENCE_FATAL" for item in fatal),
    "zlm_contract_ok": not any("STALE" in item.get("code", "") or item.get("code") == "STALE_COORDINATE_VIOLATION" for item in fatal),
    "kinetic_delta_ok": kinetic_delta_ok,
    "isr_event_count": isr_log.get("isr_event_count", 0),
    "time_threshold": {
        "threshold_ms": threshold_ms,
        "sealed_step_timestamps_available": len(sealed_timestamps) >= 2,
        "mtime_advisory_only": True,
        "warning_count": sum(1 for item in warnings if item.get("code") == "TIME_TEAR_WARNING"),
    },
    "step_count": len(steps),
    "steps": step_reports,
    "fatal_count": len(fatal),
    "fatal": fatal,
    "warning_count": len(warnings),
    "warnings": warnings,
}

text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
if report_path is not None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(text, encoding="utf-8")
print(text, end="")
if fatal:
    raise SystemExit(1)
PY

echo "========================================================================"
echo "Genesis v20.2 replay verification complete"
echo "========================================================================"

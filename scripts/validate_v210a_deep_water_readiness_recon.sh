#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V210A_PACK_ROOT:-/tmp/genesis_v210a_deep_water_recon_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V210A_REPORT_ROOT:-/tmp/genesis_v210a_deep_water_recon_reports}"
LOG_PATH="${GENESIS_VALIDATE_V210A_LOG:-/tmp/genesis_validate_v210a_deep_water_recon.log}"

echo "========================================================================"
echo "Genesis v21.0a Deep-Water Readiness Recon Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_V210A_PACK_ROOT="$PACK_ROOT" \
GENESIS_V210A_RUN_ID="read_only_recon_pack" \
    ./scripts/run_v210a_deep_water_readiness_recon.sh | tee "$LOG_PATH"

PACK_DIR="$PACK_ROOT/read_only_recon_pack"
REPORT_PATH="$REPORT_ROOT/replay_report.json"

GENESIS_V202_REPORT_PATH="$REPORT_PATH" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_DIR" | tee -a "$LOG_PATH"

python3 - "$PACK_DIR" "$REPORT_PATH" <<'PY'
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
plan = json.loads((pack / "json/00_intent_plan.json").read_text(encoding="utf-8"))

assert manifest["schema_version"] == "v20.3", manifest
assert manifest["run_profile"] == "v21.0a-read-only-recon", manifest
assert manifest["read_only_recon"] is True, manifest
assert manifest["armed"] is False, manifest
assert manifest["temporal_hardening"]["sealed_step_timestamps"] is True, manifest

assert summary["read_only_recon"] is True, summary
assert summary["armed"] is False, summary
assert summary["posted"] is False, summary
assert summary["physical_input_posted"] is False, summary
assert summary["os_driver_active"] is False, summary
assert summary["domain_locked"] is True, summary
assert summary["stop_reason"] in {
    "plan_ready_read_only_boundary",
    "plan_not_ready_read_only_boundary",
}, summary

assert plan["posted"] is False, plan
assert plan["physical_input_posted"] is False, plan
assert plan["os_driver_active"] is False, plan

assert report["status"] == "ok", report
assert report["armed"] is False, report
assert report["run_profile"] == "v21.0a-read-only-recon", report
assert report["read_only_recon"] is True, report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["step_count"] == 0, report
assert report["time_threshold"]["sealed_step_timestamps_available"] is True, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report

print(json.dumps({
    "event": "v210a_deep_water_recon_assertions",
    "status": "ok",
    "target_url": summary.get("target_url"),
    "plan_ready": summary.get("plan_ready"),
    "stop_reason": summary.get("stop_reason"),
    "report_status": report.get("status"),
    "time_tear_fatal_enforced": report["time_threshold"]["time_tear_fatal_enforced"],
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v21.0a validation complete"
echo "========================================================================"

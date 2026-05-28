#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V210B_PACK_ROOT:-/tmp/genesis_v210b_wikipedia_search_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V210B_REPORT_ROOT:-/tmp/genesis_v210b_wikipedia_search_reports}"
LOG_PATH="${GENESIS_VALIDATE_V210B_LOG:-/tmp/genesis_validate_v210b_wikipedia_search.log}"

echo "========================================================================"
echo "Genesis v21.0b Wikipedia Armed Search Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_V210B_PACK_ROOT="$PACK_ROOT" \
GENESIS_V210B_RUN_ID="dry_run_pack" \
    ./scripts/run_v210b_wikipedia_armed_search.sh | tee "$LOG_PATH"

GENESIS_V202_REPORT_PATH="$REPORT_ROOT/dry_run_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_ROOT/dry_run_pack" | tee -a "$LOG_PATH"

python3 - "$PACK_ROOT/dry_run_pack" "$REPORT_ROOT/dry_run_report.json" <<'PY'
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
plan = json.loads((pack / "json/00_intent_plan.json").read_text(encoding="utf-8"))

assert manifest["run_profile"] == "v21.0b-wikipedia-search", manifest
assert manifest["armed"] is False, manifest
assert plan["plan_profile"] == "wikipedia_search", plan
assert plan["plan_ready"] is True, plan
assert plan["search_field_found"] is True, plan
assert plan["search_commit_found"] is True, plan
assert summary["armed"] is False, summary
assert summary["stop_reason"] == "dry_run_plan_execution_boundary", summary
assert summary["posted"] is False, summary
assert summary["physical_input_posted"] is False, summary
assert summary["os_driver_active"] is False, summary
assert report["status"] == "ok", report
assert report["cryptographic_seal_ok"] is True, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report

print(json.dumps({
    "event": "v210b_wikipedia_search_dry_run_assertions",
    "status": "ok",
    "target_sequence_count": plan.get("target_sequence_count"),
}, sort_keys=True))
PY

GENESIS_V210B_PACK_ROOT="$PACK_ROOT" \
GENESIS_V210B_RUN_ID="armed_pack" \
GENESIS_V210B_ARMED_CONFIRM=GENESIS_V210B_ARMED_WIKIPEDIA_SEARCH \
GENESIS_V210B_AUTO_FIRE_CONFIRM=GENESIS_V210B_AUTO_FIRE_WIKIPEDIA_SEARCH \
    ./scripts/run_v210b_wikipedia_armed_search.sh | tee -a "$LOG_PATH"

GENESIS_V202_REPORT_PATH="$REPORT_ROOT/armed_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_ROOT/armed_pack" | tee -a "$LOG_PATH"

python3 - "$PACK_ROOT/armed_pack" "$REPORT_ROOT/armed_report.json" <<'PY'
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
plan = json.loads((pack / "json/00_intent_plan.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest["run_profile"] == "v21.0b-wikipedia-search", manifest
assert manifest["armed"] is True, manifest
assert plan["plan_profile"] == "wikipedia_search", plan
assert plan["plan_ready"] is True, plan
assert summary["armed"] is True, summary
assert summary["sequence_complete"] is True, summary
assert summary["fresh_remap_before_each_step"] is True, summary
assert summary["stale_plan_coordinates_used"] is False, summary
assert summary["field_ready"] is True, summary
assert summary["commit_click_posted"] is True, summary
assert summary["business_state_asserted"] is True, summary
assert summary["domain_locked_after_commit"] is True, summary
assert summary["url_changed"] is True, summary
assert summary["physical_input_posted"] is True, summary
assert terminal["residual_sockets_detected"] is False, terminal

assert report["status"] == "ok", report
assert report["armed"] is True, report
assert report["run_profile"] == "v21.0b-wikipedia-search", report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["kinetic_delta_ok"] is True, report
assert report["step_count"] == 2, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report

print(json.dumps({
    "event": "v210b_wikipedia_search_armed_assertions",
    "status": "ok",
    "field_transport": summary.get("field_transport"),
    "url_after_commit": summary.get("url_after_commit"),
    "sequence_complete": summary.get("sequence_complete"),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v21.0b validation complete"
echo "========================================================================"

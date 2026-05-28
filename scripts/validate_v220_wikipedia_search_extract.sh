#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V220_PACK_ROOT:-/tmp/genesis_v220_wikipedia_extract_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V220_REPORT_ROOT:-/tmp/genesis_v220_wikipedia_extract_reports}"
LOG_PATH="${GENESIS_VALIDATE_V220_LOG:-/tmp/genesis_validate_v220_wikipedia_extract.log}"

echo "========================================================================"
echo "Genesis v22.0 Wikipedia Result Extraction Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_V220_PACK_ROOT="$PACK_ROOT" \
GENESIS_V220_RUN_ID="dry_run_pack" \
    ./scripts/run_v220_wikipedia_search_extract.sh | tee "$LOG_PATH"

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

assert manifest["run_profile"] == "v22.0-wikipedia-result-extraction", manifest
assert manifest["armed"] is False, manifest
assert summary["armed"] is False, summary
assert summary["stop_reason"] == "dry_run_plan_execution_boundary", summary
assert summary["posted"] is False, summary
assert report["status"] == "ok", report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report
print(json.dumps({"event": "v220_dry_run_assertions", "status": "ok"}, sort_keys=True))
PY

GENESIS_V220_PACK_ROOT="$PACK_ROOT" \
GENESIS_V220_RUN_ID="armed_pack" \
GENESIS_V210B_ARMED_CONFIRM=GENESIS_V210B_ARMED_WIKIPEDIA_SEARCH \
GENESIS_V210B_AUTO_FIRE_CONFIRM=GENESIS_V210B_AUTO_FIRE_WIKIPEDIA_SEARCH \
    ./scripts/run_v220_wikipedia_search_extract.sh | tee -a "$LOG_PATH"

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
extraction = json.loads((pack / "json/03_step-2-result-extraction_post_assert.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest["run_profile"] == "v22.0-wikipedia-result-extraction", manifest
assert manifest["armed"] is True, manifest
assert summary["armed"] is True, summary
assert summary["sequence_complete"] is True, summary
assert summary["fresh_remap_before_each_step"] is True, summary
assert summary["stale_plan_coordinates_used"] is False, summary
assert summary["business_state_asserted"] is True, summary
assert summary["domain_locked_after_commit"] is True, summary
assert summary["url_changed"] is True, summary
assert summary["result_extraction_requested"] is True, summary
assert summary["result_extraction_asserted"] is True, summary
assert summary["result_url"] and "wikipedia.org" in summary["result_url"], summary
assert summary["result_title"], summary
assert isinstance(summary["result_lead_text_length"], int) and summary["result_lead_text_length"] >= 40, summary
assert extraction["extraction_asserted"] is True, extraction
assert extraction["result_title_found"] is True, extraction
assert extraction["lead_text_found"] is True, extraction
assert terminal["residual_sockets_detected"] is False, terminal

assert report["status"] == "ok", report
assert report["armed"] is True, report
assert report["run_profile"] == "v22.0-wikipedia-result-extraction", report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["kinetic_delta_ok"] is True, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report
print(json.dumps({
    "event": "v220_armed_extraction_assertions",
    "status": "ok",
    "result_url": summary.get("result_url"),
    "result_title": summary.get("result_title"),
    "lead_text_length": summary.get("result_lead_text_length"),
}, ensure_ascii=False, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v22.0 validation complete"
echo "========================================================================"

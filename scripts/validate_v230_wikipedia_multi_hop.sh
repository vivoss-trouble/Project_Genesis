#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V230_PACK_ROOT:-/tmp/genesis_v230_wikipedia_multi_hop_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V230_REPORT_ROOT:-/tmp/genesis_v230_wikipedia_multi_hop_reports}"
LOG_PATH="${GENESIS_VALIDATE_V230_LOG:-/tmp/genesis_validate_v230_wikipedia_multi_hop.log}"

echo "========================================================================"
echo "Genesis v23.0 Wikipedia Multi-Hop Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_V230_PACK_ROOT="$PACK_ROOT" \
GENESIS_V230_RUN_ID="dry_run_pack" \
    ./scripts/run_v230_wikipedia_multi_hop.sh | tee "$LOG_PATH"

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

assert manifest["run_profile"] == "v23.0-wikipedia-multi-hop", manifest
assert manifest["armed"] is False, manifest
assert summary["armed"] is False, summary
assert summary["stop_reason"] == "dry_run_plan_execution_boundary", summary
assert summary["posted"] is False, summary
assert report["status"] == "ok", report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report
print(json.dumps({"event": "v230_dry_run_assertions", "status": "ok"}, sort_keys=True))
PY

GENESIS_V230_PACK_ROOT="$PACK_ROOT" \
GENESIS_V230_RUN_ID="armed_pack" \
GENESIS_V210B_ARMED_CONFIRM=GENESIS_V210B_ARMED_WIKIPEDIA_SEARCH \
GENESIS_V210B_AUTO_FIRE_CONFIRM=GENESIS_V210B_AUTO_FIRE_WIKIPEDIA_SEARCH \
    ./scripts/run_v230_wikipedia_multi_hop.sh | tee -a "$LOG_PATH"

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
first_extraction = json.loads((pack / "json/03_step-2-result-extraction_post_assert.json").read_text(encoding="utf-8"))
link_pre = json.loads((pack / "json/03_step-2-follow-internal-link_pre_remap.json").read_text(encoding="utf-8"))
second_extraction = json.loads((pack / "json/04_step-3-second-result-extraction_post_assert.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest["run_profile"] == "v23.0-wikipedia-multi-hop", manifest
assert manifest["armed"] is True, manifest
assert summary["armed"] is True, summary
assert summary["sequence_complete"] is True, summary
assert summary["multi_hop_step_count"] == 2, summary
assert summary["first_extraction_asserted"] is True, summary
assert summary["internal_link_plan_ready"] is True, summary
assert summary["second_click_posted"] is True, summary
assert summary["second_url_changed"] is True, summary
assert summary["second_extraction_asserted"] is True, summary
assert summary["fresh_remap_before_each_step"] is True, summary
assert summary["stale_plan_coordinates_used"] is False, summary
assert first_extraction["extraction_asserted"] is True, first_extraction
assert link_pre["fresh_remap_done"] is True, link_pre
assert (link_pre["source_event"] or {})["tie_breaker"] == "main_content_first_y", link_pre
assert second_extraction["extraction_asserted"] is True, second_extraction
assert terminal["residual_sockets_detected"] is False, terminal
assert report["status"] == "ok", report
assert report["armed"] is True, report
assert report["run_profile"] == "v23.0-wikipedia-multi-hop", report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["kinetic_delta_ok"] is True, report
assert report["step_count"] == 3, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report
print(json.dumps({
    "event": "v230_armed_multi_hop_assertions",
    "status": "ok",
    "first_url": summary.get("result_url"),
    "second_url": summary.get("second_result_url"),
    "second_title": summary.get("second_result_title"),
}, ensure_ascii=False, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v23.0 validation complete"
echo "========================================================================"

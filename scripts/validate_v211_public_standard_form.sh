#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V211_PACK_ROOT:-/tmp/genesis_v211_evidence_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V211_REPORT_ROOT:-/tmp/genesis_v211_replay_reports}"
LOG_PATH="${GENESIS_VALIDATE_V211_LOG:-/tmp/genesis_validate_v211_public_standard_form.log}"

echo "========================================================================"
echo "Genesis v21.1 Public Standard Form Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_V211_PACK_ROOT="$PACK_ROOT" \
GENESIS_V211_RUN_ID="dry_run_pack" \
    ./scripts/run_v211_public_standard_form.sh | tee "$LOG_PATH"

python3 - "$PACK_ROOT/dry_run_pack" <<'PY'
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
plan = json.loads((pack / "json/00_intent_plan.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest.get("schema_version") == "v20.3", manifest
assert manifest.get("run_profile") == "v21.1-standard-public-form", manifest
assert manifest.get("armed") is False, manifest
assert plan.get("plan_profile") == "httpbin_standard_form", plan
assert plan.get("plan_ready") is True, plan
assert plan.get("target_sequence_count") == 2, plan
assert summary.get("armed") is False, summary
assert summary.get("stop_reason") == "dry_run_plan_execution_boundary", summary
assert terminal.get("residual_sockets_detected") is False, terminal

print(json.dumps({
    "event": "v211_dry_run_assertions",
    "status": "ok",
    "pack_dir": str(pack),
}, sort_keys=True))
PY

GENESIS_V211_PACK_ROOT="$PACK_ROOT" \
GENESIS_V211_RUN_ID="armed_pack" \
GENESIS_V211_ARMED_CONFIRM=GENESIS_V211_ARMED_PUBLIC_STANDARD_FORM \
GENESIS_V211_AUTO_FIRE_CONFIRM=GENESIS_V211_AUTO_FIRE_PUBLIC_STANDARD_FORM \
    ./scripts/run_v211_public_standard_form.sh | tee -a "$LOG_PATH"

python3 - "$PACK_ROOT/armed_pack" <<'PY'
import hashlib
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest.get("schema_version") == "v20.3", manifest
assert manifest.get("run_profile") == "v21.1-standard-public-form", manifest
assert manifest.get("armed") is True, manifest
assert summary.get("armed") is True, summary
assert summary.get("plan_ready") is True, summary
assert summary.get("field_ready") is True, summary
assert summary.get("commit_click_posted") is True, summary
assert summary.get("url_changed") is True, summary
assert summary.get("response_state_asserted") is True, summary
assert summary.get("sequence_complete") is True, summary
assert summary.get("fresh_remap_before_each_step") is True, summary
assert summary.get("stale_plan_coordinates_used") is False, summary
assert terminal.get("residual_sockets_detected") is False, terminal

paths = {item["path"]: item for item in manifest.get("files") or []}
required = [
    "json/00_intent_plan.json",
    "json/01_step-0-fill-customer-name_pre_remap.json",
    "json/01_step-0-fill-customer-name_driver_receipt.json",
    "json/01_step-0-fill-customer-name_post_assert.json",
    "json/02_step-1-submit-form_pre_remap.json",
    "json/02_step-1-submit-form_driver_receipt.json",
    "json/02_step-1-submit-form_post_assert.json",
    "json/99_terminal_scan_report.json",
    "json/99_v20_summary.json",
    "raw/v211_exec_results.jsonl",
]
missing = [path for path in required if path not in paths]
assert not missing, missing

for rel, item in paths.items():
    path = pack / rel
    assert path.exists(), rel
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], rel

print(json.dumps({
    "event": "v211_armed_assertions",
    "status": "ok",
    "pack_dir": str(pack),
    "field_transport": summary.get("field_transport"),
}, sort_keys=True))
PY

GENESIS_V202_REPORT_PATH="$REPORT_ROOT/dry_run_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_ROOT/dry_run_pack" | tee -a "$LOG_PATH"

python3 - "$REPORT_ROOT/dry_run_report.json" <<'PY'
import json
import pathlib
import sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["status"] == "ok", report
assert report["armed"] is False, report
assert report["run_profile"] == "v21.1-standard-public-form", report
print(json.dumps({"event": "v211_dry_run_replay_assertions", "status": "ok"}, sort_keys=True))
PY

GENESIS_V202_REPORT_PATH="$REPORT_ROOT/armed_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_ROOT/armed_pack" | tee -a "$LOG_PATH"

python3 - "$REPORT_ROOT/armed_report.json" <<'PY'
import json
import pathlib
import sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["status"] == "ok", report
assert report["armed"] is True, report
assert report["run_profile"] == "v21.1-standard-public-form", report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["kinetic_delta_ok"] is True, report
assert report["step_count"] == 2, report
assert report["time_threshold"]["time_tear_fatal_enforced"] is True, report
print(json.dumps({"event": "v211_armed_replay_assertions", "status": "ok"}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v21.1 validation complete"
echo "========================================================================"

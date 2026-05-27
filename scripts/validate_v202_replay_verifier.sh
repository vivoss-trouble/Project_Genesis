#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PACK_ROOT="${GENESIS_VALIDATE_V202_PACK_ROOT:-/tmp/genesis_v202_replay_packs}"
REPORT_ROOT="${GENESIS_VALIDATE_V202_REPORT_ROOT:-/tmp/genesis_v202_replay_reports}"
LOG_PATH="${GENESIS_VALIDATE_V202_LOG:-/tmp/genesis_validate_v202_replay_verifier.log}"

echo "========================================================================"
echo "Genesis v20.2 Replay Verifier Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT" "$REPORT_ROOT"
mkdir -p "$PACK_ROOT" "$REPORT_ROOT"

GENESIS_VALIDATE_V201_PACK_ROOT="$PACK_ROOT" \
GENESIS_VALIDATE_V201_LOG="$LOG_PATH.v201" \
    ./scripts/validate_v201_evidence_pack.sh | tee "$LOG_PATH"

GENESIS_V202_REPORT_PATH="$REPORT_ROOT/dry_run_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$PACK_ROOT/dry_run_pack" | tee -a "$LOG_PATH"

python3 - "$REPORT_ROOT/dry_run_report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["status"] == "ok", report
assert report["armed"] is False, report
assert report["cryptographic_seal_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["step_count"] == 0, report
print(json.dumps({"event": "v202_dry_run_replay_assertions", "status": "ok"}, sort_keys=True))
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
assert report["cryptographic_seal_ok"] is True, report
assert report["arrow_of_time_order_ok"] is True, report
assert report["zlm_contract_ok"] is True, report
assert report["kinetic_delta_ok"] is True, report
assert report["step_count"] == 3, report
assert all(step["fresh_remap_done"] is True for step in report["steps"]), report
assert all(step["stale_plan_coordinates_used"] is False for step in report["steps"]), report
assert report["time_threshold"]["mtime_advisory_only"] is True, report
print(json.dumps({"event": "v202_armed_replay_assertions", "status": "ok"}, sort_keys=True))
PY

TAMPERED_PACK="$PACK_ROOT/tampered_pack"
cp -R "$PACK_ROOT/armed_pack" "$TAMPERED_PACK"
python3 - "$TAMPERED_PACK/json/99_v20_summary.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["sequence_complete"] = False
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

set +e
GENESIS_V202_REPORT_PATH="$REPORT_ROOT/tampered_report.json" \
    ./scripts/replay_v202_evidence_pack.sh "$TAMPERED_PACK" >>"$LOG_PATH" 2>&1
tamper_status=$?
set -e
if [[ $tamper_status -eq 0 ]]; then
    echo "[v20.2] ERROR: tampered pack unexpectedly passed replay verification" >&2
    exit 1
fi

python3 - "$REPORT_ROOT/tampered_report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
codes = {item["code"] for item in report["fatal"]}
assert "TAMPERED_EVIDENCE_FATAL" in codes, report
print(json.dumps({"event": "v202_tamper_redline_assertions", "status": "ok"}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v20.2 validation complete"
echo "========================================================================"

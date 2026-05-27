#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V201_LOG:-/tmp/genesis_validate_v201_evidence_pack.log}"
PACK_ROOT="${GENESIS_VALIDATE_V201_PACK_ROOT:-/tmp/genesis_v201_evidence_packs}"

echo "========================================================================"
echo "Genesis v20.1 Evidence Pack Validation"
echo "========================================================================"

rm -rf "$PACK_ROOT"
mkdir -p "$PACK_ROOT"

GENESIS_V201_PACK_ROOT="$PACK_ROOT" \
GENESIS_V201_RUN_ID="dry_run_pack" \
    ./scripts/run_v201_evidence_pack.sh | tee "$LOG_PATH"

python3 - "$PACK_ROOT/dry_run_pack" <<'PY'
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
plan = json.loads((pack / "json/00_intent_plan.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest.get("schema_version") == "v20.1", manifest
assert manifest.get("armed") is False, manifest
assert manifest.get("append_only_policy") is True, manifest
assert manifest.get("json_fatal") is True, manifest
assert manifest.get("screenshot_best_effort") is True, manifest
assert manifest.get("file_count", 0) >= 6, manifest
assert plan.get("plan_ready") is True, plan
assert summary.get("armed") is False, summary
assert summary.get("stop_reason") == "dry_run_plan_execution_boundary", summary
assert terminal.get("residual_sockets_detected") is False, terminal

paths = {item["path"] for item in manifest.get("files") or []}
assert "json/00_intent_plan.json" in paths, paths
assert "json/99_v20_summary.json" in paths, paths
assert "json/99_terminal_scan_report.json" in paths, paths

print(json.dumps({
    "event": "v201_dry_run_evidence_assertions",
    "status": "ok",
    "file_count": manifest.get("file_count"),
    "pack_dir": str(pack),
}, sort_keys=True))
PY

GENESIS_V201_PACK_ROOT="$PACK_ROOT" \
GENESIS_V201_RUN_ID="armed_pack" \
GENESIS_V201_ARMED_CONFIRM=GENESIS_V201_ARMED_EVIDENCE_PACK \
GENESIS_V201_AUTO_FIRE_CONFIRM=GENESIS_V201_AUTO_FIRE_EVIDENCE_PACK \
    ./scripts/run_v201_evidence_pack.sh | tee -a "$LOG_PATH"

python3 - "$PACK_ROOT/armed_pack" <<'PY'
import hashlib
import json
import pathlib
import sys

pack = pathlib.Path(sys.argv[1])
manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
summary = json.loads((pack / "json/99_v20_summary.json").read_text(encoding="utf-8"))
terminal = json.loads((pack / "json/99_terminal_scan_report.json").read_text(encoding="utf-8"))

assert manifest.get("armed") is True, manifest
assert summary.get("armed") is True, summary
assert summary.get("sequence_complete") is True, summary
assert summary.get("fresh_remap_before_each_step") is True, summary
assert summary.get("stale_plan_coordinates_used") is False, summary
assert summary.get("business_state_asserted") is True, summary
assert terminal.get("residual_sockets_detected") is False, terminal

paths = {item["path"]: item for item in manifest.get("files") or []}
required = [
    "json/00_intent_plan.json",
    "json/01_step-0-trigger-modal_pre_remap.json",
    "json/01_step-0-trigger-modal_post_assert.json",
    "json/02_step-1-fill-text-field_pre_remap.json",
    "json/02_step-1-fill-text-field_post_assert.json",
    "json/03_step-2-commit-form_pre_remap.json",
    "json/03_step-2-commit-form_driver_receipt.json",
    "json/03_step-2-commit-form_post_assert.json",
    "json/50_isr_intervention_log.json",
    "json/99_terminal_scan_report.json",
    "json/99_v20_summary.json",
]
missing = [path for path in required if path not in paths]
assert not missing, missing

for rel, item in paths.items():
    path = pack / rel
    assert path.exists(), rel
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"], rel

step_asserts = [
    json.loads((pack / "json/01_step-0-trigger-modal_post_assert.json").read_text(encoding="utf-8")),
    json.loads((pack / "json/02_step-1-fill-text-field_post_assert.json").read_text(encoding="utf-8")),
    json.loads((pack / "json/03_step-2-commit-form_post_assert.json").read_text(encoding="utf-8")),
]
assert all(item["receipt"].get("fresh_remap_done") is True for item in step_asserts), step_asserts
assert all(item["receipt"].get("stale_plan_coordinates_used") is False for item in step_asserts), step_asserts

print(json.dumps({
    "event": "v201_armed_evidence_assertions",
    "status": "ok",
    "file_count": manifest.get("file_count"),
    "pack_dir": str(pack),
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v20.1 validation complete"
echo "========================================================================"

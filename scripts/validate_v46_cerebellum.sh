#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="${GENESIS_LIVE_FIRE_RUN_ID:-v46-cerebellum-baseline}"
OUT_DIR="${GENESIS_LIVE_FIRE_OUT_DIR:-.genesis-state/live-fire/$RUN_ID}"

echo "========================================================================"
echo "Genesis v4.6 Cerebellum Shooter Baseline Validation"
echo "Run ID: $RUN_ID"
echo "Output: $OUT_DIR"
echo "========================================================================"

GENESIS_TEST_DYNAMIC_ADVISORY_MODEL=1 \
GENESIS_LIVE_FIRE_SEC="${GENESIS_LIVE_FIRE_SEC:-20}" \
GENESIS_LIVE_FIRE_RUN_ID="$RUN_ID" \
    ./scripts/validate_v44_real_model_live_fire.sh

python3 scripts/project_audit_sqlite.py \
    --audit "$OUT_DIR/audit.jsonl" \
    --db "$OUT_DIR/audit.sqlite" \
    --telemetry-report \
    --assert-v46-baseline

echo "========================================================================"
echo "Genesis v4.6 cerebellum baseline validation passed"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export GENESIS_V210B_RUN_PROFILE="${GENESIS_V210B_RUN_PROFILE:-v22.0-wikipedia-result-extraction}"
export GENESIS_V210B_RESULT_EXTRACTION=1
export GENESIS_V210B_PACK_ROOT="${GENESIS_V220_PACK_ROOT:-${GENESIS_V210B_PACK_ROOT:-$ROOT_DIR/evidence_packs}}"
export GENESIS_V210B_RUN_ID="${GENESIS_V220_RUN_ID:-${GENESIS_V210B_RUN_ID:-run_v220_$(date -u +%Y%m%dT%H%M%SZ)_$(git rev-parse --short HEAD)_$$}}"

exec ./scripts/run_v210b_wikipedia_armed_search.sh

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================================================"
echo "Genesis v5.3 Armed Manual Gate Dry-Run Validation"
echo "========================================================================"

./scripts/run_v53_armed_native_dummy.sh

echo "========================================================================"
echo "Genesis v5.3 armed manual gate dry-run validation passed"
echo "========================================================================"

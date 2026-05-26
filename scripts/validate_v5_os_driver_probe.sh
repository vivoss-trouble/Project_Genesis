#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================================================"
echo "Genesis v5 OS Driver Probe Validation"
echo "========================================================================"

cargo check -p genesis-os-driver --all-targets
cargo run -p genesis-os-driver -- probe
cargo run -p genesis-os-driver -- selftest

echo "========================================================================"
echo "Genesis v5 OS driver probe validation passed"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================================================"
echo "Genesis v5.4 Vision Marker Baseline Validation"
echo "========================================================================"

./scripts/validate_v52_native_dummy_window.sh

cargo test -p genesis-frame-grabber marker_detector -- --nocapture

./scripts/validate_v5_vision_daemon.sh

echo "========================================================================"
echo "Genesis v5.4 vision marker baseline validation passed"
echo "========================================================================"

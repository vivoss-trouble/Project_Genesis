#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V56_LOG:-/tmp/genesis_validate_v56_window_scoped_capture.log}"

echo "========================================================================"
echo "Genesis v5.6 Window-Scoped Vision Capture Validation"
echo "========================================================================"

GENESIS_V55_AUTO_VISIBLE=1 \
    ./scripts/run_v55_vision_marker_single_shot.sh | tee "$LOG_PATH"

grep -F '"capture_scope": "window"' "$LOG_PATH" >/dev/null || {
    echo "[v5.6] ERROR: expected window-scoped capture evidence" >&2
    exit 1
}

grep -F '"marker_detection": {' "$LOG_PATH" >/dev/null || {
    echo "[v5.6] ERROR: expected non-null marker_detection" >&2
    exit 1
}

grep -F '"event": "vision_action_point"' "$LOG_PATH" >/dev/null || {
    echo "[v5.6] ERROR: expected transformed vision_action_point evidence" >&2
    exit 1
}

grep -F '"posted": false' "$LOG_PATH" >/dev/null || {
    echo "[v5.6] ERROR: validation must remain dry-run and post no physical click" >&2
    exit 1
}

echo "========================================================================"
echo "Genesis v5.6 window-scoped vision capture validation passed"
echo "========================================================================"

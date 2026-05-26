#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "========================================================================"
echo "Genesis v5 Frame Grabber Probe Validation"
echo "========================================================================"

cargo check -p genesis-frame-grabber --all-targets

set +e
OUTPUT="$(cargo run -p genesis-frame-grabber 2>/tmp/genesis_frame_grabber_probe.err)"
STATUS=$?
set -e

printf '%s\n' "$OUTPUT"
python3 - "$STATUS" "$OUTPUT" <<'PY'
import json
import sys

status = int(sys.argv[1])
payload = json.loads(sys.argv[2])

assert payload["backend"] in {"macos-coregraphics", "unsupported"}, payload
assert isinstance(payload["capture_supported"], bool), payload
assert isinstance(payload["screen_capture_allowed"], bool), payload
assert payload["capture_latency_ms"] >= 0, payload

if payload["capture_supported"] and payload["screen_capture_allowed"]:
    assert status == 0, payload
    assert payload["pixel_width"] and payload["pixel_width"] > 0, payload
    assert payload["pixel_height"] and payload["pixel_height"] > 0, payload
else:
    assert status != 0, payload
    assert payload["error"], payload

print("[v5-frame-grabber] probe protocol passed")
PY

echo "========================================================================"
echo "Genesis v5 frame grabber probe validation passed"
echo "========================================================================"

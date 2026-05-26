#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BINARY="/tmp/genesis_native_dummy_window_validate"

cleanup() {
    rm -f "$BINARY"
}
trap cleanup EXIT

echo "========================================================================"
echo "Genesis v5.2 Native Dummy Window Validation"
echo "========================================================================"

swiftc scripts/native_dummy_window.swift -o "$BINARY"
OUTPUT="$("$BINARY" --selftest --window-x 160 --window-y 160)"
printf '%s\n' "$OUTPUT"

python3 - "$OUTPUT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["event"] == "selftest", payload
assert payload["target_id"] == "native-heal", payload
window = payload["window"]
target = payload["target_logical_rect"]
center = payload["target_global_logical_center"]
quartz_center = payload["target_quartz_logical_center"]
screen_height = payload["screen_logical_height"]

assert window == {"height": 260, "width": 420, "x": 160, "y": 160}, payload
assert target == {"height": 70, "width": 120, "x": 150, "y": 95}, payload
assert center == {"x": 370, "y": 290}, payload
assert screen_height > 0, payload
assert quartz_center == {"x": 370, "y": screen_height - 290}, payload
print("[v5.2-native-dummy] deterministic target geometry passed")
PY

./scripts/validate_v51_spatiotemporal.sh

echo "========================================================================"
echo "Genesis v5.2 native dummy window validation passed"
echo "========================================================================"

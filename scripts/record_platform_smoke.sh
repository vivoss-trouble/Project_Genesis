#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_DIR="${GENESIS_PLATFORM_SMOKE_DIR:-$ROOT/.genesis-state/platform-smoke}"
PLATFORM_ID="${GENESIS_PLATFORM_ID:-}"
CURRENT_STEP="init"

cd "$ROOT"

detect_platform() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || true)"
  case "$uname_s" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

if [[ -z "$PLATFORM_ID" ]]; then
  PLATFORM_ID="$(detect_platform)"
fi

if [[ "$PLATFORM_ID" != "macos" && "$PLATFORM_ID" != "linux" && "$PLATFORM_ID" != "windows" ]]; then
  echo "[platform_smoke] current-host smoke supports desktop host platforms only; platform=$PLATFORM_ID" >&2
  exit 2
fi

mkdir -p "$SMOKE_DIR"
MANIFEST_PATH="$SMOKE_DIR/$PLATFORM_ID.json"
HEALTH_PATH="$SMOKE_DIR/$PLATFORM_ID-desktop-shell-health.json"

write_failure_manifest() {
  local exit_code="$1"
  local reason="${2:-${CURRENT_STEP}_failed}"
  python3 - "$MANIFEST_PATH" "$ROOT" "$PLATFORM_ID" "$exit_code" "$reason" "$CURRENT_STEP" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
platform = sys.argv[3]
exit_code = int(sys.argv[4])
reason = sys.argv[5]
current_step = sys.argv[6]

git_head = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=root,
    capture_output=True,
    text=True,
).stdout.strip() or "unknown"
dirty_paths = subprocess.run(
    ["git", "status", "--short"],
    cwd=root,
    capture_output=True,
    text=True,
).stdout.splitlines()

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "platform": platform,
    "status": "failed",
    "current_step": current_step,
    "reason": reason,
    "exit_code": exit_code,
    "real_host_smoke": True,
    "smoke_kind": "desktop_shell_health",
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="desktop_shell_health"
echo "[platform_smoke] desktop shell health platform=$PLATFORM_ID"
cargo run -q -p genesis-desktop-shell -- health > "$HEALTH_PATH"

CURRENT_STEP="success_manifest"
python3 - "$MANIFEST_PATH" "$ROOT" "$PLATFORM_ID" "$HEALTH_PATH" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import platform as py_platform
import subprocess
import sys

manifest_path = Path(sys.argv[1])
root = Path(sys.argv[2])
platform_id = sys.argv[3]
health_path = Path(sys.argv[4])

def run(args):
    return subprocess.run(
        args,
        cwd=root,
        capture_output=True,
        text=True,
    )

git_head = run(["git", "rev-parse", "HEAD"]).stdout.strip() or "unknown"
dirty_paths = run(["git", "status", "--short"]).stdout.splitlines()
rustc = run(["rustc", "-vV"]).stdout
host_triple = ""
for line in rustc.splitlines():
    if line.startswith("host: "):
        host_triple = line.split("host: ", 1)[1].strip()
        break

health = json.loads(health_path.read_text(encoding="utf-8"))
health_bytes = health_path.read_bytes()
expected_platform = {
    "macos": "MacOs",
    "linux": "Linux",
    "windows": "Windows",
}[platform_id]
if health.get("platform") != expected_platform:
    raise SystemExit(
        f"desktop shell reported platform={health.get('platform')} expected={expected_platform}"
    )
if health.get("sdk_contract_epoch") != "genesis-sdk-shell-v1":
    raise SystemExit("desktop shell health did not report genesis-sdk-shell-v1")
if health.get("sdk_abi_version") != 1:
    raise SystemExit("desktop shell health did not report SDK ABI v1")

manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "platform": platform_id,
    "status": "passed",
    "real_host_smoke": True,
    "smoke_kind": "desktop_shell_health",
    "sdk_contract_epoch": health["sdk_contract_epoch"],
    "sdk_abi_version": health["sdk_abi_version"],
    "runtime_profile": health["profile"],
    "reported_platform": health["platform"],
    "host_triple": host_triple,
    "host_os": py_platform.system(),
    "host_machine": py_platform.machine(),
    "health_artifact": {
        "path": str(health_path),
        "sha256": hashlib.sha256(health_bytes).hexdigest(),
        "bytes": len(health_bytes),
    },
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "[platform_smoke] evidence=$MANIFEST_PATH"

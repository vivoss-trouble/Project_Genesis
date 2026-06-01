#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ID="${GENESIS_MOBILE_PLATFORM_ID:-${GENESIS_PLATFORM_ID:-}}"
SMOKE_DIR="${GENESIS_PLATFORM_SMOKE_DIR:-$ROOT/.genesis-state/platform-smoke}"
DEVICE_ID="${GENESIS_MOBILE_DEVICE_ID:-}"
DEVICE_OS_VERSION="${GENESIS_MOBILE_OS_VERSION:-}"
DEVICE_PROOF="${GENESIS_MOBILE_DEVICE_PROOF:-}"
VERIFY_CMD="${GENESIS_MOBILE_DEVICE_VERIFY_CMD:-}"
REMOTE_BASE_URL="${GENESIS_MOBILE_REMOTE_BASE_URL:-https://genesis-node.invalid}"
CURRENT_STEP="init"

cd "$ROOT"

case "$PLATFORM_ID" in
  ios|android)
    ;;
  *)
    echo "[mobile_smoke] GENESIS_MOBILE_PLATFORM_ID must be ios or android" >&2
    exit 2
    ;;
esac

if [[ -z "$DEVICE_ID" || -z "$DEVICE_OS_VERSION" ]]; then
  echo "[mobile_smoke] GENESIS_MOBILE_DEVICE_ID and GENESIS_MOBILE_OS_VERSION are required" >&2
  exit 2
fi

if [[ -z "$DEVICE_PROOF" || ! -f "$DEVICE_PROOF" ]]; then
  echo "[mobile_smoke] GENESIS_MOBILE_DEVICE_PROOF must point to an existing device proof file" >&2
  exit 2
fi

if [[ -z "$VERIFY_CMD" ]]; then
  echo "[mobile_smoke] GENESIS_MOBILE_DEVICE_VERIFY_CMD is required" >&2
  exit 2
fi

mkdir -p "$SMOKE_DIR"
MANIFEST_PATH="$SMOKE_DIR/$PLATFORM_ID.json"

write_failure_manifest() {
  local exit_code="$1"
  local reason="${2:-${CURRENT_STEP}_failed}"
  python3 - "$MANIFEST_PATH" "$ROOT" "$PLATFORM_ID" "$DEVICE_ID" "$DEVICE_OS_VERSION" "$DEVICE_PROOF" "$VERIFY_CMD" "$REMOTE_BASE_URL" "$exit_code" "$reason" "$CURRENT_STEP" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
platform = sys.argv[3]
device_id = sys.argv[4]
device_os_version = sys.argv[5]
device_proof = Path(sys.argv[6])
verify_cmd = sys.argv[7]
remote_base_url = sys.argv[8]
exit_code = int(sys.argv[9])
reason = sys.argv[10]
current_step = sys.argv[11]

git_head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip() or "unknown"
dirty_paths = subprocess.run(["git", "status", "--short"], cwd=root, capture_output=True, text=True).stdout.splitlines()
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
    "smoke_kind": "mobile_control_device",
    "device": {
        "id_sha256": hashlib.sha256(device_id.encode("utf-8")).hexdigest(),
        "os_version": device_os_version,
        "proof_path": str(device_proof),
        "proof_exists": device_proof.exists(),
        "verify_command_sha256": hashlib.sha256(verify_cmd.encode("utf-8")).hexdigest(),
    },
    "remote_base_url": remote_base_url,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="sdk_mobile_control_tests"
cargo test -p genesis-mobile-control mobile_control_smoke_proves_remote_only_health_action_and_evidence

CURRENT_STEP="device_proof_verify"
GENESIS_MOBILE_DEVICE_PROOF="$DEVICE_PROOF" bash -lc "$VERIFY_CMD"

CURRENT_STEP="success_manifest"
python3 - "$MANIFEST_PATH" "$ROOT" "$PLATFORM_ID" "$DEVICE_ID" "$DEVICE_OS_VERSION" "$DEVICE_PROOF" "$VERIFY_CMD" "$REMOTE_BASE_URL" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys

manifest_path = Path(sys.argv[1])
root = Path(sys.argv[2])
platform_id = sys.argv[3]
device_id = sys.argv[4]
device_os_version = sys.argv[5]
device_proof = Path(sys.argv[6])
verify_cmd = sys.argv[7]
remote_base_url = sys.argv[8]

def run(args):
    return subprocess.run(args, cwd=root, capture_output=True, text=True)

def sha256_file(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

git_head = run(["git", "rev-parse", "HEAD"]).stdout.strip() or "unknown"
dirty_paths = run(["git", "status", "--short"]).stdout.splitlines()
rustc = run(["rustc", "-vV"]).stdout
host_triple = ""
for line in rustc.splitlines():
    if line.startswith("host: "):
        host_triple = line.split("host: ", 1)[1].strip()
        break

proof_bytes = device_proof.read_bytes()
manifest_path.parent.mkdir(parents=True, exist_ok=True)
manifest_path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "platform": platform_id,
    "status": "passed",
    "real_host_smoke": True,
    "smoke_kind": "mobile_control_device",
    "sdk_contract_epoch": "genesis-sdk-shell-v1",
    "sdk_abi_version": 1,
    "runtime_profile": "MobileControl",
    "remote_base_url": remote_base_url,
    "runner_host_triple": host_triple,
    "device": {
        "id_sha256": hashlib.sha256(device_id.encode("utf-8")).hexdigest(),
        "os_version": device_os_version,
        "proof_artifact": {
            "path": str(device_proof),
            "sha256": hashlib.sha256(proof_bytes).hexdigest(),
            "bytes": len(proof_bytes),
        },
        "verify_command_sha256": hashlib.sha256(verify_cmd.encode("utf-8")).hexdigest(),
    },
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "[mobile_smoke] evidence=$MANIFEST_PATH"

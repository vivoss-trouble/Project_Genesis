#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${GENESIS_PREFLIGHT_KIND:-}"
OUT_DIR="${GENESIS_PREFLIGHT_OUT_DIR:-$ROOT/.genesis-state/preflight-external-evidence}"
PROOF="${GENESIS_PREFLIGHT_PROOF:-}"
ARTIFACT="${GENESIS_PREFLIGHT_ARTIFACT:-}"
VERIFY_CMD="${GENESIS_PREFLIGHT_VERIFY_CMD:-true}"
LABEL="${GENESIS_PREFLIGHT_LABEL:-}"
CURRENT_STEP="init"

cd "$ROOT"

case "$KIND" in
  desktop_macos|desktop_linux|desktop_windows|ios_simulator|android_emulator|self_signed_artifact)
    ;;
  *)
    echo "[preflight_evidence] invalid GENESIS_PREFLIGHT_KIND=$KIND" >&2
    exit 2
    ;;
esac

if [[ -n "$PROOF" && ! -f "$PROOF" ]]; then
  echo "[preflight_evidence] GENESIS_PREFLIGHT_PROOF must point to an existing file when set" >&2
  exit 2
fi

if [[ -n "$ARTIFACT" && ! -f "$ARTIFACT" ]]; then
  echo "[preflight_evidence] GENESIS_PREFLIGHT_ARTIFACT must point to an existing file when set" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
EVIDENCE_PATH="$OUT_DIR/$KIND.json"

write_manifest() {
  local status="$1"
  local reason="${2:-}"
  local exit_code="${3:-}"
  python3 - "$EVIDENCE_PATH" "$ROOT" "$KIND" "$PROOF" "$ARTIFACT" "$VERIFY_CMD" "$LABEL" "$status" "$reason" "$exit_code" "$CURRENT_STEP" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import platform
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
kind = sys.argv[3]
proof = Path(sys.argv[4]) if sys.argv[4] else None
artifact = Path(sys.argv[5]) if sys.argv[5] else None
verify_cmd = sys.argv[6]
label = sys.argv[7]
status = sys.argv[8]
reason = sys.argv[9]
exit_code = sys.argv[10]
current_step = sys.argv[11]

def sha256_file(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def run(args):
    return subprocess.run(args, cwd=root, capture_output=True, text=True, check=False)

git_head = run(["git", "rev-parse", "HEAD"]).stdout.strip() or "unknown"
dirty_paths = run(["git", "status", "--short"]).stdout.splitlines()
rustc = run(["rustc", "-vV"]).stdout
host_triple = ""
for line in rustc.splitlines():
    if line.startswith("host: "):
        host_triple = line.split("host: ", 1)[1].strip()
        break

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "reason": reason,
    "kind": kind,
    "label": label,
    "preflight_evidence": True,
    "not_release_evidence": True,
    "real_host_smoke": False,
    "real_signing_evidence": False,
    "runner_host": {
        "os": platform.system(),
        "machine": platform.machine(),
        "rust_host_triple": host_triple,
    },
    "verification": {
        "command_sha256": hashlib.sha256(verify_cmd.encode("utf-8")).hexdigest(),
        "exit_code": int(exit_code) if exit_code else 0,
    },
}
if proof is not None:
    manifest["proof_artifact"] = {
        "path": str(proof),
        "bytes": proof.stat().st_size if proof.exists() else 0,
        "sha256": sha256_file(proof) if proof.exists() else None,
    }
if artifact is not None:
    manifest["artifact"] = {
        "path": str(artifact),
        "bytes": artifact.stat().st_size if artifact.exists() else 0,
        "sha256": sha256_file(artifact) if artifact.exists() else None,
    }
if status != "passed":
    manifest["current_step"] = current_step
if exit_code:
    manifest["exit_code"] = int(exit_code)

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_failure_manifest() {
  local exit_code="$1"
  trap - ERR
  write_manifest "failed" "${CURRENT_STEP}_failed" "$exit_code" || true
  echo "[preflight_evidence] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="verify"
GENESIS_PREFLIGHT_PROOF="$PROOF" \
GENESIS_PREFLIGHT_ARTIFACT="$ARTIFACT" \
  bash -lc "$VERIFY_CMD"

CURRENT_STEP="manifest"
write_manifest "passed"
echo "[preflight_evidence] evidence=$EVIDENCE_PATH"

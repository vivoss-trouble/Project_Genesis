#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${GENESIS_RELEASE_SIGNING_KIND:-}"
ARTIFACT="${GENESIS_RELEASE_SIGNING_ARTIFACT:-}"
VERIFY_CMD="${GENESIS_RELEASE_SIGNING_VERIFY_CMD:-}"
LABEL="${GENESIS_RELEASE_SIGNING_LABEL:-}"
SIGNING_DIR="${GENESIS_RELEASE_SIGNING_DIR:-$ROOT/.genesis-state/release-signing}"
CURRENT_STEP="init"

cd "$ROOT"

case "$KIND" in
  desktop_installer|desktop_signing|desktop_notarization|ios_development_signing|android_development_signing)
    ;;
  *)
    echo "[release_signing] invalid GENESIS_RELEASE_SIGNING_KIND=$KIND" >&2
    exit 2
    ;;
esac

if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
  echo "[release_signing] GENESIS_RELEASE_SIGNING_ARTIFACT must point to an existing file" >&2
  exit 2
fi

if [[ -z "$VERIFY_CMD" ]]; then
  echo "[release_signing] GENESIS_RELEASE_SIGNING_VERIFY_CMD is required" >&2
  exit 2
fi

EVIDENCE_PATH="$SIGNING_DIR/$KIND.json"

write_signing_manifest() {
  local status="$1"
  local reason="${2:-}"
  local exit_code="${3:-}"
  python3 - "$EVIDENCE_PATH" "$ROOT" "$KIND" "$ARTIFACT" "$VERIFY_CMD" "$LABEL" "$status" "$reason" "$exit_code" "$CURRENT_STEP" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
kind = sys.argv[3]
artifact = Path(sys.argv[4])
verify_cmd = sys.argv[5]
label = sys.argv[6]
status = sys.argv[7]
reason = sys.argv[8]
exit_code = sys.argv[9]
current_step = sys.argv[10]

def sha256_file(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def git(args):
    return subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()

git_head = git(["rev-parse", "HEAD"]) or "unknown"
dirty_paths = git(["status", "--short"]).splitlines()
manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "reason": reason,
    "kind": kind,
    "real_signing_evidence": status == "passed",
    "artifact": {
        "path": str(artifact),
        "bytes": artifact.stat().st_size if artifact.exists() else 0,
        "sha256": sha256_file(artifact) if artifact.exists() else None,
    },
    "verification": {
        "label": label,
        "command_sha256": hashlib.sha256(verify_cmd.encode("utf-8")).hexdigest(),
        "exit_code": int(exit_code) if exit_code else 0,
    },
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
  write_signing_manifest "failed" "${CURRENT_STEP}_failed" "$exit_code" || true
  echo "[release_signing] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="verify"
GENESIS_RELEASE_SIGNING_ARTIFACT="$ARTIFACT" bash -lc "$VERIFY_CMD"

CURRENT_STEP="manifest"
write_signing_manifest "passed"
echo "[release_signing] evidence=$EVIDENCE_PATH"

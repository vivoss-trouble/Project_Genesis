#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_MANIFEST="${GENESIS_RELEASE_SIGNING_MANIFEST:-${1:-}}"
SIGNING_DIR="${GENESIS_RELEASE_SIGNING_DIR:-$ROOT/.genesis-state/release-signing}"

cd "$ROOT"

if [[ -z "$SOURCE_MANIFEST" || ! -f "$SOURCE_MANIFEST" ]]; then
  echo "[release_signing_import] GENESIS_RELEASE_SIGNING_MANIFEST must point to an existing manifest" >&2
  exit 2
fi

python3 - "$SOURCE_MANIFEST" "$SIGNING_DIR" "$ROOT" <<'PY'
from pathlib import Path
import json
import shutil
import subprocess
import sys

source = Path(sys.argv[1])
signing_dir = Path(sys.argv[2])
root = Path(sys.argv[3])

required = {
    "desktop_installer",
    "desktop_signing",
    "desktop_notarization",
    "ios_development_signing",
    "android_development_signing",
}

git_head = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=root,
    capture_output=True,
    text=True,
    check=False,
).stdout.strip()

try:
    manifest = json.loads(source.read_text(encoding="utf-8"))
except json.JSONDecodeError as error:
    raise SystemExit(f"invalid JSON: {error}")

kind = manifest.get("kind")
artifact = manifest.get("artifact")
verification = manifest.get("verification")
if kind not in required:
    raise SystemExit(f"invalid signing kind: {kind}")
if manifest.get("schema_version") != 1:
    raise SystemExit("schema_version must be 1")
if manifest.get("status") != "passed":
    raise SystemExit(f"manifest status must be passed: {manifest.get('status')}")
if manifest.get("git_head") != git_head:
    raise SystemExit(
        f"manifest git_head mismatch: expected={git_head} actual={manifest.get('git_head')}"
    )
if manifest.get("git_dirty") is not False:
    raise SystemExit("manifest git_dirty must be false")
if manifest.get("real_signing_evidence") is not True:
    raise SystemExit("manifest must set real_signing_evidence=true")
if not isinstance(artifact, dict) or not artifact.get("sha256") or artifact.get("bytes", 0) <= 0:
    raise SystemExit("manifest artifact hash/size is missing")
if not isinstance(verification, dict) or verification.get("exit_code") != 0:
    raise SystemExit("manifest verification exit_code must be 0")

signing_dir.mkdir(parents=True, exist_ok=True)
target = signing_dir / f"{kind}.json"
shutil.copyfile(source, target)
print(f"[release_signing_import] imported kind={kind} evidence={target}")
PY

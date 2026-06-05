#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${GENESIS_EXTERNAL_EVIDENCE_BUNDLE:-${1:-}}"
EVIDENCE_DIR="${GENESIS_AUTONOMOUS_EVIDENCE_DIR:-$ROOT/.genesis-state/autonomous-blueprint}"
SMOKE_DIR="${GENESIS_PLATFORM_SMOKE_DIR:-$EVIDENCE_DIR/platform-smoke}"
SIGNING_DIR="${GENESIS_RELEASE_SIGNING_DIR:-$EVIDENCE_DIR/release-signing}"
MATRIX_PATH="${GENESIS_REAL_PLATFORM_MATRIX_EVIDENCE:-$EVIDENCE_DIR/real-platform-matrix.json}"

cd "$ROOT"

if [[ -z "$BUNDLE_DIR" || ! -d "$BUNDLE_DIR" ]]; then
  echo "[external_evidence] GENESIS_EXTERNAL_EVIDENCE_BUNDLE must point to an existing directory" >&2
  exit 2
fi

mkdir -p "$SMOKE_DIR" "$SIGNING_DIR"

if [[ -d "$BUNDLE_DIR/platform-smoke" ]]; then
  for platform in android ios linux macos windows; do
    manifest="$BUNDLE_DIR/platform-smoke/$platform.json"
    if [[ -f "$manifest" ]]; then
      GENESIS_PLATFORM_SMOKE_MANIFEST="$manifest" \
      GENESIS_PLATFORM_SMOKE_DIR="$SMOKE_DIR" \
        bash "$ROOT/scripts/import_platform_smoke_manifest.sh"
    fi
  done
fi

if [[ -d "$BUNDLE_DIR/release-signing" ]]; then
  while IFS= read -r -d '' manifest; do
    GENESIS_RELEASE_SIGNING_MANIFEST="$manifest" \
    GENESIS_RELEASE_SIGNING_DIR="$SIGNING_DIR" \
      bash "$ROOT/scripts/import_release_signing_manifest.sh"
  done < <(find "$BUNDLE_DIR/release-signing" -maxdepth 1 -name '*.json' -print0 | sort -z)
fi

GENESIS_PLATFORM_SMOKE_DIR="$SMOKE_DIR" \
GENESIS_REAL_PLATFORM_MATRIX_EVIDENCE="$MATRIX_PATH" \
GENESIS_REQUIRE_REAL_PLATFORM_MATRIX="${GENESIS_REQUIRE_REAL_PLATFORM_MATRIX:-0}" \
  bash "$ROOT/scripts/validate_real_platform_matrix.sh"

python3 - "$EVIDENCE_DIR/external-evidence-collection.json" "$ROOT" "$BUNDLE_DIR" "$SMOKE_DIR" "$SIGNING_DIR" "$MATRIX_PATH" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
bundle_dir = Path(sys.argv[3])
smoke_dir = Path(sys.argv[4])
signing_dir = Path(sys.argv[5])
matrix_path = Path(sys.argv[6])

git_head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip() or "unknown"
dirty_paths = subprocess.run(["git", "status", "--short"], cwd=root, capture_output=True, text=True).stdout.splitlines()
matrix = json.loads(matrix_path.read_text(encoding="utf-8")) if matrix_path.exists() else {}
signing = {}
for kind in (
    "desktop_installer",
    "desktop_signing",
    "desktop_notarization",
    "ios_development_signing",
    "android_development_signing",
):
    manifest = signing_dir / f"{kind}.json"
    signing[kind] = {
        "path": str(manifest),
        "exists": manifest.exists(),
    }
    if manifest.exists():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            signing[kind].update({
                "status": data.get("status"),
                "git_head": data.get("git_head"),
                "real_signing_evidence": data.get("real_signing_evidence"),
            })
        except json.JSONDecodeError as error:
            signing[kind]["json_error"] = str(error)

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": "passed",
    "bundle_dir": str(bundle_dir),
    "platform_smoke_dir": str(smoke_dir),
    "release_signing_dir": str(signing_dir),
    "platform_matrix": {
        "path": str(matrix_path),
        "status": matrix.get("status"),
        "claim": matrix.get("claim"),
        "verified_platforms": matrix.get("verified_platforms"),
        "missing_platforms": matrix.get("missing_platforms"),
    },
    "signing_evidence": signing,
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "[external_evidence] evidence=$EVIDENCE_DIR/external-evidence-collection.json"

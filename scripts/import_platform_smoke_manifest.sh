#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_MANIFEST="${GENESIS_PLATFORM_SMOKE_MANIFEST:-${1:-}}"
SMOKE_DIR="${GENESIS_PLATFORM_SMOKE_DIR:-$ROOT/.genesis-state/platform-smoke}"

cd "$ROOT"

if [[ -z "$SOURCE_MANIFEST" || ! -f "$SOURCE_MANIFEST" ]]; then
  echo "[platform_smoke_import] GENESIS_PLATFORM_SMOKE_MANIFEST must point to an existing manifest" >&2
  exit 2
fi

python3 - "$SOURCE_MANIFEST" "$SMOKE_DIR" "$ROOT" <<'PY'
from pathlib import Path
import json
import shutil
import subprocess
import sys

source = Path(sys.argv[1])
smoke_dir = Path(sys.argv[2])
root = Path(sys.argv[3])

required = {"macos", "linux", "windows", "ios", "android"}
desktop = {"macos", "linux", "windows"}
mobile = {"ios", "android"}

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

platform = manifest.get("platform")
if platform not in required:
    raise SystemExit(f"invalid platform: {platform}")
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
if manifest.get("real_host_smoke") is not True:
    raise SystemExit("manifest must set real_host_smoke=true")
if platform in desktop and manifest.get("smoke_kind") != "desktop_shell_health":
    raise SystemExit(
        f"desktop platform requires smoke_kind=desktop_shell_health: {manifest.get('smoke_kind')}"
    )
if platform in mobile and manifest.get("smoke_kind") != "mobile_control_device":
    raise SystemExit(
        f"mobile platform requires smoke_kind=mobile_control_device: {manifest.get('smoke_kind')}"
    )

smoke_dir.mkdir(parents=True, exist_ok=True)
target = smoke_dir / f"{platform}.json"
shutil.copyfile(source, target)
print(f"[platform_smoke_import] imported platform={platform} evidence={target}")
PY

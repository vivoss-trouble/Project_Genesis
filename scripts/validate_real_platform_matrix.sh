#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_DIR="${GENESIS_PLATFORM_SMOKE_DIR:-$ROOT/.genesis-state/platform-smoke}"
EVIDENCE_PATH="${GENESIS_REAL_PLATFORM_MATRIX_EVIDENCE:-$ROOT/.genesis-state/real-platform-matrix.json}"
REQUIRE_FULL="${GENESIS_REQUIRE_REAL_PLATFORM_MATRIX:-0}"
CURRENT_STEP="init"

cd "$ROOT"

write_matrix_manifest() {
  local status="$1"
  local reason="${2:-}"
  local exit_code="${3:-}"
  python3 - "$EVIDENCE_PATH" "$ROOT" "$SMOKE_DIR" "$status" "$reason" "$exit_code" "$CURRENT_STEP" "$REQUIRE_FULL" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
smoke_dir = Path(sys.argv[3])
status = sys.argv[4]
reason = sys.argv[5]
exit_code = sys.argv[6]
current_step = sys.argv[7]
require_full = sys.argv[8] == "1"

required = ["macos", "linux", "windows", "ios", "android"]
desktop = {"macos", "linux", "windows"}
mobile = {"ios", "android"}

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

platforms = {}
verified = []
missing = []
invalid = []
for platform in required:
    manifest_path = smoke_dir / f"{platform}.json"
    entry = {
        "manifest": str(manifest_path),
        "manifest_exists": manifest_path.exists(),
        "required_for_full_matrix": True,
        "shell_kind": "mobile_control" if platform in mobile else "desktop_node",
        "verification": "missing",
    }
    if not manifest_path.exists():
        missing.append(platform)
        platforms[platform] = entry
        continue
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        entry["verification"] = "invalid"
        entry["reason"] = f"invalid_json:{error}"
        invalid.append(platform)
        platforms[platform] = entry
        continue
    entry["status"] = manifest.get("status")
    entry["git_head"] = manifest.get("git_head")
    entry["git_dirty"] = manifest.get("git_dirty")
    entry["real_host_smoke"] = manifest.get("real_host_smoke")
    entry["smoke_kind"] = manifest.get("smoke_kind")
    if manifest.get("schema_version") != 1:
        entry["verification"] = "invalid"
        entry["reason"] = "schema_version_mismatch"
        invalid.append(platform)
    elif manifest.get("platform") != platform:
        entry["verification"] = "invalid"
        entry["reason"] = "platform_mismatch"
        invalid.append(platform)
    elif manifest.get("status") != "passed":
        entry["verification"] = "invalid"
        entry["reason"] = "smoke_not_passed"
        invalid.append(platform)
    elif manifest.get("git_head") != git_head:
        entry["verification"] = "invalid"
        entry["reason"] = "git_head_mismatch"
        invalid.append(platform)
    elif manifest.get("real_host_smoke") is not True:
        entry["verification"] = "invalid"
        entry["reason"] = "not_real_host_smoke"
        invalid.append(platform)
    elif platform in desktop and manifest.get("smoke_kind") != "desktop_shell_health":
        entry["verification"] = "invalid"
        entry["reason"] = "desktop_smoke_kind_mismatch"
        invalid.append(platform)
    elif platform in mobile and manifest.get("smoke_kind") != "mobile_control_device":
        entry["verification"] = "invalid"
        entry["reason"] = "mobile_smoke_kind_mismatch"
        invalid.append(platform)
    else:
        entry["verification"] = "verified"
        verified.append(platform)
    platforms[platform] = entry

if status == "auto":
    if len(verified) == len(required) and not invalid:
        status = "passed"
    elif require_full:
        status = "failed"
    else:
        status = "partial"
if invalid and status == "partial":
    reason = reason or "invalid_platform_smoke_manifest"
if missing and status == "partial":
    reason = reason or "missing_platform_smoke_manifest"

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "reason": reason,
    "required_platforms": required,
    "verified_platforms": verified,
    "missing_platforms": missing,
    "invalid_platforms": invalid,
    "platforms": platforms,
    "full_matrix_required": require_full,
    "full_matrix_verified": len(verified) == len(required) and not invalid,
    "claim": "verified" if len(verified) == len(required) and not invalid else "unverified",
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
  write_matrix_manifest "failed" "${CURRENT_STEP}_failed" "$exit_code" || true
  echo "[real_platform_matrix] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="matrix_manifest"
write_matrix_manifest "auto"

python3 - "$EVIDENCE_PATH" "$REQUIRE_FULL" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
require_full = sys.argv[2] == "1"
manifest = json.loads(path.read_text(encoding="utf-8"))
if manifest.get("claim") == "verified" and not manifest.get("full_matrix_verified"):
    raise SystemExit("matrix cannot claim verified without full_matrix_verified")
for platform, entry in manifest.get("platforms", {}).items():
    if entry.get("verification") == "verified" and not entry.get("manifest_exists"):
        raise SystemExit(f"{platform} verified without manifest")
if require_full and manifest.get("status") != "passed":
    print(
        "[real_platform_matrix] full real platform matrix is required but not verified: "
        f"missing={manifest.get('missing_platforms')} invalid={manifest.get('invalid_platforms')}",
        file=sys.stderr,
    )
    sys.exit(3)
PY

echo "[real_platform_matrix] evidence=$EVIDENCE_PATH"

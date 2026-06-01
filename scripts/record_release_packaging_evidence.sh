#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_PATH="${GENESIS_RELEASE_PACKAGING_EVIDENCE:-$ROOT/.genesis-state/release-packaging.json}"
PLATFORM_MATRIX_PATH="${GENESIS_RELEASE_PLATFORM_MATRIX_EVIDENCE:-$ROOT/.genesis-state/real-platform-matrix.json}"
VALIDATION_EVIDENCE_PATH="${GENESIS_RELEASE_VALIDATION_EVIDENCE:-$ROOT/.genesis-state/validation-release.json}"
REQUIRE_FULL="${GENESIS_REQUIRE_RELEASE_PACKAGING:-0}"
CURRENT_STEP="init"

cd "$ROOT"

write_packaging_manifest() {
  local status="$1"
  local reason="${2:-}"
  local exit_code="${3:-}"
  python3 - "$EVIDENCE_PATH" "$ROOT" "$PLATFORM_MATRIX_PATH" "$VALIDATION_EVIDENCE_PATH" "$status" "$reason" "$exit_code" "$CURRENT_STEP" "$REQUIRE_FULL" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tomllib

path = Path(sys.argv[1])
root = Path(sys.argv[2])
platform_matrix_path = Path(sys.argv[3])
validation_path = Path(sys.argv[4])
status = sys.argv[5]
reason = sys.argv[6]
exit_code = sys.argv[7]
current_step = sys.argv[8]
require_full = sys.argv[9] == "1"

def git(args):
    return subprocess.run(
        ["git", *args],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()

def sha256_file(file_path):
    digest = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def load_json(file_path):
    try:
        return json.loads(file_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as error:
        return {"status": "invalid", "json_error": str(error)}

def cargo_package_version(package_name):
    cargo_toml = root / package_name / "Cargo.toml"
    package_data = tomllib.loads(cargo_toml.read_text(encoding="utf-8"))
    version = package_data.get("package", {}).get("version")
    if isinstance(version, dict) and version.get("workspace") is True:
        workspace = tomllib.loads((root / "Cargo.toml").read_text(encoding="utf-8"))
        return workspace.get("workspace", {}).get("package", {}).get("version")
    return version

def sdk_contract_constants():
    source = (root / "genesis-sdk" / "src" / "lib.rs").read_text(encoding="utf-8")
    epoch_match = re.search(
        r'GENESIS_SDK_SHELL_CONTRACT_EPOCH:\s*&str\s*=\s*"([^"]+)"',
        source,
    )
    abi_match = re.search(
        r"GENESIS_SDK_SHELL_ABI_VERSION:\s*u32\s*=\s*(\d+)",
        source,
    )
    return {
        "shell_contract_epoch": epoch_match.group(1) if epoch_match else None,
        "shell_abi_version": int(abi_match.group(1)) if abi_match else None,
    }

def artifact_entry(file_path, kind, package):
    file_path = Path(file_path)
    return {
        "package": package,
        "kind": kind,
        "path": str(file_path),
        "bytes": file_path.stat().st_size,
        "sha256": sha256_file(file_path),
    }

git_head = git(["rev-parse", "HEAD"]) or "unknown"
dirty_paths = git(["status", "--short"]).splitlines()
platform_matrix = load_json(platform_matrix_path)
validation = load_json(validation_path)
sdk_contract = sdk_contract_constants()

desktop_binary = root / "target" / "release" / ("genesis-desktop-shell.exe" if os.name == "nt" else "genesis-desktop-shell")
artifacts = []
if desktop_binary.exists():
    artifacts.append(artifact_entry(desktop_binary, "desktop_shell_binary", "genesis-desktop-shell"))
for pattern, kind, package in (
    ("target/release/deps/libgenesis_sdk-*.rlib", "rust_library", "genesis-sdk"),
    ("target/release/deps/libgenesis_mobile_control-*.rlib", "rust_library", "genesis-mobile-control"),
):
    matches = sorted(root.glob(pattern), key=lambda candidate: candidate.stat().st_mtime, reverse=True)
    if matches:
        artifacts.append(artifact_entry(matches[0], kind, package))

platform_manifest = {
    "path": str(platform_matrix_path),
    "exists": platform_matrix_path.exists(),
}
if isinstance(platform_matrix, dict):
    platform_manifest.update({
        "status": platform_matrix.get("status"),
        "claim": platform_matrix.get("claim"),
        "full_matrix_verified": platform_matrix.get("full_matrix_verified"),
        "git_head": platform_matrix.get("git_head"),
        "sha256": sha256_file(platform_matrix_path) if platform_matrix_path.exists() else None,
    })

validation_profile = {
    "path": str(validation_path),
    "exists": validation_path.exists(),
}
if isinstance(validation, dict):
    validation_profile.update({
        "status": validation.get("status"),
        "profile": validation.get("profile"),
        "git_head": validation.get("git_head"),
        "sha256": sha256_file(validation_path) if validation_path.exists() else None,
    })

requirements = {
    "artifact_hashes": "passed" if artifacts else "missing",
    "sdk_version": "passed" if cargo_package_version("genesis-sdk") else "missing",
    "sdk_contract_constants": "passed" if sdk_contract["shell_contract_epoch"] and sdk_contract["shell_abi_version"] is not None else "missing",
    "platform_manifest_link": "passed" if platform_manifest.get("exists") and platform_manifest.get("git_head") == git_head else "missing",
    "validation_profile_link": "passed" if validation_profile.get("exists") and validation_profile.get("status") == "passed" and validation_profile.get("git_head") == git_head else "missing",
    "desktop_package_smoke": "passed" if desktop_binary.exists() else "missing",
    "desktop_installer": "missing",
    "desktop_signing": "missing",
    "desktop_notarization": "missing",
    "ios_development_signing": "missing",
    "android_development_signing": "missing",
    "mobile_network_permission_documentation": "passed" if (root / "docs" / "mobile-release-behavior-phase5.md").exists() else "missing",
    "mobile_background_behavior_documentation": "passed" if (root / "docs" / "mobile-release-behavior-phase5.md").exists() else "missing",
}

hard_link_requirements = (
    "artifact_hashes",
    "sdk_version",
    "sdk_contract_constants",
    "platform_manifest_link",
    "validation_profile_link",
    "desktop_package_smoke",
)
release_complete_requirements = tuple(requirements)
hard_links_passed = all(requirements[name] == "passed" for name in hard_link_requirements)
release_complete = all(requirements[name] == "passed" for name in release_complete_requirements)

if status == "auto":
    if release_complete:
        status = "passed"
    elif require_full:
        status = "failed"
    else:
        status = "partial"
if status == "partial" and not reason:
    missing = [name for name, value in requirements.items() if value != "passed"]
    reason = "missing_release_packaging_evidence:" + ",".join(missing)

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "reason": reason,
    "sdk": {
        "package": "genesis-sdk",
        "version": cargo_package_version("genesis-sdk"),
        **sdk_contract,
    },
    "artifacts": artifacts,
    "platform_manifest": platform_manifest,
    "validation_profile": validation_profile,
    "requirements": requirements,
    "hard_links_passed": hard_links_passed,
    "release_complete": release_complete,
    "full_packaging_required": require_full,
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
  write_packaging_manifest "failed" "${CURRENT_STEP}_failed" "$exit_code" || true
  echo "[release_packaging] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

trap 'write_failure_manifest "$?"' ERR

CURRENT_STEP="release_build"
cargo build --release -p genesis-desktop-shell -p genesis-mobile-control -p genesis-sdk

CURRENT_STEP="desktop_package_smoke"
"$ROOT/target/release/genesis-desktop-shell" health >/dev/null

CURRENT_STEP="packaging_manifest"
write_packaging_manifest "auto"

python3 - "$EVIDENCE_PATH" "$REQUIRE_FULL" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
require_full = sys.argv[2] == "1"
manifest = json.loads(path.read_text(encoding="utf-8"))
if not manifest.get("hard_links_passed"):
    raise SystemExit("release packaging evidence did not link artifacts, sdk version, platform manifest, and validation profile")
for artifact in manifest.get("artifacts", []):
    if not artifact.get("sha256") or len(artifact.get("sha256", "")) != 64:
        raise SystemExit(f"artifact missing sha256: {artifact.get('path')}")
if require_full and manifest.get("status") != "passed":
    missing = [name for name, status in manifest.get("requirements", {}).items() if status != "passed"]
    print(
        "[release_packaging] full release packaging is required but not verified: "
        f"missing={missing}",
        file=sys.stderr,
    )
    sys.exit(3)
PY

echo "[release_packaging] evidence=$EVIDENCE_PATH"

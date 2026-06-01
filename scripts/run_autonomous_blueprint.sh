#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED_MODE="${GENESIS_AUTONOMOUS_MODE:-fast}"
MODE="$REQUESTED_MODE"
AUTONOMOUS_REASON=""
CURRENT_STEP="init"
EVIDENCE_DIR="${GENESIS_AUTONOMOUS_EVIDENCE_DIR:-$ROOT/.genesis-state/autonomous-blueprint}"
mkdir -p "$EVIDENCE_DIR"

cd "$ROOT"

write_invalid_mode_summary() {
  python3 - "$EVIDENCE_DIR/autonomous-summary.json" "$REQUESTED_MODE" "$ROOT" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

summary_path = Path(sys.argv[1])
requested_mode = sys.argv[2]
root = Path(sys.argv[3])

def metadata(root):
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
    return {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "git_head": git_head,
        "git_dirty": bool(dirty_paths),
    }

manifest = {
    **metadata(root),
    "mode": requested_mode,
    "effective_mode": requested_mode,
    "status": "failed",
    "reason": "invalid_mode",
    "current_step": "mode_validation",
    "exit_code": 2,
    "primary_evidence": "autonomous_summary",
    "primary_status": "failed",
    "evidence_files": {
        "autonomous_summary": {
            "path": str(summary_path),
            "exists": True,
        },
    },
}
summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

case "$MODE" in
  fast|pilot|release|auto)
    ;;
  *)
    echo "[autonomous_blueprint] invalid GENESIS_AUTONOMOUS_MODE=$MODE; expected fast, pilot, release, or auto" >&2
    write_invalid_mode_summary
    echo "[autonomous_blueprint] evidence=$EVIDENCE_DIR/autonomous-summary.json" >&2
    exit 2
    ;;
esac

echo "[autonomous_blueprint] requested_mode=$REQUESTED_MODE"

write_release_precheck_manifest() {
  python3 - "$EVIDENCE_DIR/release-precheck.json" "$ROOT" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
root = Path(sys.argv[2])
status = subprocess.run(
    ["git", "status", "--short"],
    cwd=root,
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()
git_head = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=root,
    capture_output=True,
    text=True,
).stdout.strip() or "unknown"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(status),
    "profile": "release",
    "gate": "git_clean_precheck",
    "status": "passed" if not status else "blocked",
    "git_clean": not status,
    "dirty_paths": status,
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_autonomous_summary() {
  local status="$1"
  local reason="${2:-}"
  local exit_code="${3:-}"
  local validation_file
  case "$MODE" in
    fast)
      validation_file="validation-fast.json"
      ;;
    pilot)
      validation_file="validation-pilot.json"
      ;;
    release)
      validation_file="validation-release.json"
      ;;
    *)
      validation_file="validation-${MODE}.json"
      ;;
  esac

  python3 - "$EVIDENCE_DIR/autonomous-summary.json" "$REQUESTED_MODE" "$MODE" "$status" "$reason" "$exit_code" "$CURRENT_STEP" "$EVIDENCE_DIR" "$validation_file" "$ROOT" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

summary_path = Path(sys.argv[1])
requested_mode = sys.argv[2]
mode = sys.argv[3]
status = sys.argv[4]
reason = sys.argv[5]
exit_code = sys.argv[6]
current_step = sys.argv[7]
evidence_dir = Path(sys.argv[8])
validation_file = sys.argv[9]
root = Path(sys.argv[10])

def metadata(root):
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
    return {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "git_head": git_head,
        "git_dirty": bool(dirty_paths),
    }

files = {
    "autonomous_summary": summary_path,
    "platform_contracts": evidence_dir / "platform-contracts.json",
    "real_platform_matrix": evidence_dir / "real-platform-matrix.json",
    "release_packaging": evidence_dir / "release-packaging.json",
    "validation": evidence_dir / validation_file,
    "release_precheck": evidence_dir / "release-precheck.json",
}
if mode != "release" and requested_mode != "auto":
    files.pop("release_precheck")

if status == "blocked" and reason == "git_clean_precheck":
    primary = "release_precheck"
elif status == "failed" and current_step == "platform_contracts":
    primary = "platform_contracts"
elif status == "failed" and current_step == "real_platform_matrix":
    primary = "real_platform_matrix"
elif status == "failed" and current_step == "release_packaging":
    primary = "release_packaging"
elif status == "failed" and current_step == "validation":
    primary = "validation"
elif status == "failed":
    primary = "autonomous_summary"
else:
    primary = "validation"
summary = {
    **metadata(root),
    "effective_mode": mode,
    "mode": requested_mode,
    "status": status,
    "reason": reason,
    "current_step": current_step,
    "primary_evidence": primary,
    "evidence_files": {
        name: {
            "path": str(path),
            "exists": True if name == "autonomous_summary" else path.exists(),
        }
        for name, path in files.items()
    },
}
if exit_code:
    summary["exit_code"] = int(exit_code)

primary_path = files.get(primary)
if primary_path and primary_path.exists():
    try:
        summary["primary_status"] = json.loads(primary_path.read_text(encoding="utf-8")).get("status")
    except json.JSONDecodeError:
        summary["primary_status"] = "invalid-json"
if primary == "autonomous_summary":
    summary["primary_status"] = status

summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

validate_autonomous_summary() {
  local expected_status="$1"
  python3 - "$EVIDENCE_DIR/autonomous-summary.json" "$expected_status" <<'PY'
from pathlib import Path
import json
import sys

summary_path = Path(sys.argv[1])
expected_status = sys.argv[2]
try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    print(f"[autonomous_blueprint] missing summary manifest: {summary_path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as error:
    print(f"[autonomous_blueprint] invalid summary manifest JSON: {error}", file=sys.stderr)
    sys.exit(1)

if summary.get("status") != expected_status:
    print(
        f"[autonomous_blueprint] summary status mismatch: expected={expected_status} actual={summary.get('status')}",
        file=sys.stderr,
    )
    sys.exit(1)

if summary.get("schema_version") != 1:
    print(
        f"[autonomous_blueprint] summary schema mismatch: expected=1 actual={summary.get('schema_version')}",
        file=sys.stderr,
    )
    sys.exit(1)
if not summary.get("generated_at_utc"):
    print("[autonomous_blueprint] summary missing generated_at_utc", file=sys.stderr)
    sys.exit(1)
if not summary.get("git_head"):
    print("[autonomous_blueprint] summary missing git_head", file=sys.stderr)
    sys.exit(1)
if not isinstance(summary.get("git_dirty"), bool):
    print(
        f"[autonomous_blueprint] summary git_dirty must be boolean: actual={summary.get('git_dirty')}",
        file=sys.stderr,
    )
    sys.exit(1)

primary = summary.get("primary_evidence")
evidence_files = summary.get("evidence_files", {})
primary_record = evidence_files.get(primary)
if primary_record is None:
    print(f"[autonomous_blueprint] summary primary evidence is not listed: {primary}", file=sys.stderr)
    sys.exit(1)
if not primary_record.get("exists"):
    print(f"[autonomous_blueprint] primary evidence is missing: {primary_record.get('path')}", file=sys.stderr)
    sys.exit(1)

primary_status = summary.get("primary_status")
if expected_status == "passed" and primary_status != "passed":
    print(
        f"[autonomous_blueprint] primary evidence status mismatch: expected=passed actual={primary_status}",
        file=sys.stderr,
    )
    sys.exit(1)
if expected_status == "blocked" and primary_status != "blocked":
    print(
        f"[autonomous_blueprint] primary evidence status mismatch: expected=blocked actual={primary_status}",
        file=sys.stderr,
    )
    sys.exit(1)
if expected_status == "failed" and primary_status != "failed":
    print(
        f"[autonomous_blueprint] primary evidence status mismatch: expected=failed actual={primary_status}",
        file=sys.stderr,
    )
    sys.exit(1)

def load_evidence(name):
    record = evidence_files.get(name)
    if record is None:
        print(f"[autonomous_blueprint] missing evidence record: {name}", file=sys.stderr)
        sys.exit(1)
    path = Path(record.get("path", ""))
    if not record.get("exists") or not path.exists():
        print(f"[autonomous_blueprint] evidence file is missing: {name} path={path}", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print(f"[autonomous_blueprint] invalid evidence JSON: {name} error={error}", file=sys.stderr)
        sys.exit(1)

def check_metadata(name, evidence):
    if evidence.get("schema_version") != summary.get("schema_version"):
        print(
            f"[autonomous_blueprint] evidence schema mismatch: {name} expected={summary.get('schema_version')} actual={evidence.get('schema_version')}",
            file=sys.stderr,
        )
        sys.exit(1)
    if evidence.get("git_head") != summary.get("git_head"):
        print(
            f"[autonomous_blueprint] evidence git_head mismatch: {name} expected={summary.get('git_head')} actual={evidence.get('git_head')}",
            file=sys.stderr,
        )
        sys.exit(1)
    if evidence.get("git_dirty") != summary.get("git_dirty"):
        print(
            f"[autonomous_blueprint] evidence git_dirty mismatch: {name} expected={summary.get('git_dirty')} actual={evidence.get('git_dirty')}",
            file=sys.stderr,
        )
        sys.exit(1)
    if not evidence.get("generated_at_utc"):
        print(f"[autonomous_blueprint] evidence missing generated_at_utc: {name}", file=sys.stderr)
        sys.exit(1)
    return evidence

def check_platform_contracts(evidence):
    expected_targets = {
        "aarch64-apple-darwin",
        "x86_64-unknown-linux-gnu",
        "x86_64-pc-windows-msvc",
        "aarch64-apple-ios",
        "aarch64-linux-android",
        "wasm32-wasip1",
    }
    actual_targets = set(evidence.get("targets", []))
    if not expected_targets.issubset(actual_targets):
        print(
            "[autonomous_blueprint] platform contract target coverage mismatch: "
            f"missing={sorted(expected_targets - actual_targets)} actual={sorted(actual_targets)}",
            file=sys.stderr,
        )
        sys.exit(1)
    target_matrix = evidence.get("target_matrix", {})
    if not isinstance(target_matrix, dict):
        print("[autonomous_blueprint] platform contract target_matrix must be an object", file=sys.stderr)
        sys.exit(1)
    for target in expected_targets:
        target_checks = target_matrix.get(target)
        if not isinstance(target_checks, dict):
            print(f"[autonomous_blueprint] platform contract target_matrix missing target: {target}", file=sys.stderr)
            sys.exit(1)
        for check_name in ("workspace", "genesis_core_shell", "genesis_replay_shell"):
            if target_checks.get(check_name) != "passed":
                print(
                    "[autonomous_blueprint] platform contract target check did not pass: "
                    f"target={target} check={check_name} actual={target_checks.get(check_name)}",
                    file=sys.stderr,
                )
                sys.exit(1)

    expected_packages = {
        "genesis-platform",
        "genesis-sdk",
        "brain-llm",
        "genesis-replay",
        "genesis-os-driver",
        "genesis-frame-grabber",
    }
    actual_packages = set(evidence.get("packages", []))
    if not expected_packages.issubset(actual_packages):
        print(
            "[autonomous_blueprint] platform contract package coverage mismatch: "
            f"missing={sorted(expected_packages - actual_packages)} actual={sorted(actual_packages)}",
            file=sys.stderr,
        )
        sys.exit(1)

    required_passed_checks = (
        "platform_api_containment",
        "python_transport_containment",
        "platform_identity_containment",
        "local_service_path_containment",
        "network_transport_containment",
        "plugin_fs_containment",
        "process_cwd_containment",
        "runtime_temp_dir_containment",
        "subprocess_containment",
    )
    containment_report = evidence.get("containment_report")
    if not isinstance(containment_report, dict):
        print("[autonomous_blueprint] platform contract containment_report must be an object", file=sys.stderr)
        sys.exit(1)
    containment_checks = containment_report.get("checks")
    if not isinstance(containment_checks, dict):
        print("[autonomous_blueprint] platform contract containment_report.checks must be an object", file=sys.stderr)
        sys.exit(1)
    for check_name in required_passed_checks:
        if evidence.get(check_name) != "passed":
            print(
                f"[autonomous_blueprint] platform contract check did not pass: {check_name}={evidence.get(check_name)}",
                file=sys.stderr,
            )
            sys.exit(1)
        check_report = containment_checks.get(check_name)
        if not isinstance(check_report, dict):
            print(f"[autonomous_blueprint] platform contract containment report missing check: {check_name}", file=sys.stderr)
            sys.exit(1)
        if check_report.get("status") != "passed" or check_report.get("violation_count") != 0:
            print(
                "[autonomous_blueprint] platform contract containment report check did not pass: "
                f"{check_name} status={check_report.get('status')} violations={check_report.get('violation_count')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not isinstance(check_report.get("allowed_paths"), list):
            print(f"[autonomous_blueprint] platform contract containment report missing allowed_paths: {check_name}", file=sys.stderr)
            sys.exit(1)

    if evidence.get("core_shell", {}).get("features") != "--no-default-features":
        print("[autonomous_blueprint] platform contract core shell coverage is missing no-default-features", file=sys.stderr)
        sys.exit(1)
    if evidence.get("replay_shell", {}).get("features") != "--no-default-features":
        print("[autonomous_blueprint] platform contract replay shell coverage is missing no-default-features", file=sys.stderr)
        sys.exit(1)
    if evidence.get("warnings_as_errors") is not True:
        print("[autonomous_blueprint] platform contract warnings_as_errors must be true", file=sys.stderr)
        sys.exit(1)

def check_validation_evidence(evidence):
    mode = summary.get("effective_mode")
    expected_profile = {
        "fast": "default",
        "pilot": "pilot",
        "release": "release",
    }.get(mode)
    if expected_profile is None:
        print(f"[autonomous_blueprint] unknown effective_mode for validation evidence: {mode}", file=sys.stderr)
        sys.exit(1)
    if evidence.get("profile") != expected_profile:
        print(
            f"[autonomous_blueprint] validation profile mismatch: expected={expected_profile} actual={evidence.get('profile')}",
            file=sys.stderr,
        )
        sys.exit(1)
    gate_report = evidence.get("gate_report")
    if not isinstance(gate_report, dict):
        print("[autonomous_blueprint] validation evidence missing gate_report", file=sys.stderr)
        sys.exit(1)

    required_base_passed = (
        "rust_tests",
        "rust_clippy",
        "python_bytecode_compile",
        "python_daemon_transport_selftest",
        "platform_contracts",
    )
    for gate in required_base_passed:
        if evidence.get(gate) != "passed":
            print(
                f"[autonomous_blueprint] validation gate did not pass: {gate}={evidence.get(gate)}",
                file=sys.stderr,
            )
            sys.exit(1)
        gate_entry = gate_report.get(gate)
        if not isinstance(gate_entry, dict):
            print(f"[autonomous_blueprint] validation gate_report missing gate: {gate}", file=sys.stderr)
            sys.exit(1)
        if gate_entry.get("status") != "passed":
            print(
                f"[autonomous_blueprint] validation gate_report did not pass: {gate}={gate_entry.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if gate_entry.get("required") is not True:
            print(
                f"[autonomous_blueprint] validation gate_report required flag mismatch: {gate}={gate_entry.get('required')}",
                file=sys.stderr,
            )
            sys.exit(1)

    if mode == "fast":
        expected_skipped = (
            "java_probe",
            "java_dependency_scan",
            "local_lm_smoke",
            "lazarus_stress",
        )
        skip_reasons = evidence.get("skip_reasons")
        if not isinstance(skip_reasons, dict):
            print("[autonomous_blueprint] fast validation evidence missing skip_reasons", file=sys.stderr)
            sys.exit(1)
        for gate in expected_skipped:
            if evidence.get(gate) != "skipped":
                print(
                    f"[autonomous_blueprint] fast validation gate should be skipped: {gate}={evidence.get(gate)}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if not skip_reasons.get(gate):
                print(f"[autonomous_blueprint] fast validation missing skip reason: {gate}", file=sys.stderr)
                sys.exit(1)
            gate_entry = gate_report.get(gate)
            if not isinstance(gate_entry, dict):
                print(f"[autonomous_blueprint] fast validation gate_report missing gate: {gate}", file=sys.stderr)
                sys.exit(1)
            if gate_entry.get("status") != "skipped" or not gate_entry.get("skip_reason"):
                print(
                    "[autonomous_blueprint] fast validation gate_report skip mismatch: "
                    f"{gate} status={gate_entry.get('status')} skip_reason={gate_entry.get('skip_reason')}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if gate_entry.get("required") is not False:
                print(
                    f"[autonomous_blueprint] fast validation skipped gate must not be required: {gate}={gate_entry.get('required')}",
                    file=sys.stderr,
                )
                sys.exit(1)
        if skip_reasons.get("platform_contracts"):
            print(
                f"[autonomous_blueprint] platform contracts passed but has skip reason: {skip_reasons.get('platform_contracts')}",
                file=sys.stderr,
            )
            sys.exit(1)
    elif mode == "pilot":
        if evidence.get("lazarus_stress") != "passed":
            print(
                f"[autonomous_blueprint] pilot validation requires lazarus_stress=passed: actual={evidence.get('lazarus_stress')}",
                file=sys.stderr,
            )
            sys.exit(1)
        gate_entry = gate_report.get("lazarus_stress")
        if not isinstance(gate_entry, dict) or gate_entry.get("status") != "passed" or gate_entry.get("required") is not True:
            print(
                "[autonomous_blueprint] pilot validation gate_report must require passed lazarus_stress: "
                f"entry={gate_entry}",
                file=sys.stderr,
            )
            sys.exit(1)
    elif mode == "release":
        for gate in ("java_probe", "java_dependency_scan", "local_lm_smoke", "lazarus_stress"):
            if evidence.get(gate) != "passed":
                print(
                    f"[autonomous_blueprint] release validation gate did not pass: {gate}={evidence.get(gate)}",
                    file=sys.stderr,
                )
                sys.exit(1)
            gate_entry = gate_report.get(gate)
            if not isinstance(gate_entry, dict) or gate_entry.get("status") != "passed" or gate_entry.get("required") is not True:
                print(
                    "[autonomous_blueprint] release validation gate_report must require passed external gate: "
                    f"{gate} entry={gate_entry}",
                    file=sys.stderr,
                )
                sys.exit(1)

def check_real_platform_matrix(evidence):
    expected_platforms = {"macos", "linux", "windows", "ios", "android"}
    actual_platforms = set(evidence.get("required_platforms", []))
    if expected_platforms != actual_platforms:
        print(
            "[autonomous_blueprint] real platform matrix required platform mismatch: "
            f"expected={sorted(expected_platforms)} actual={sorted(actual_platforms)}",
            file=sys.stderr,
        )
        sys.exit(1)
    platforms = evidence.get("platforms")
    if not isinstance(platforms, dict):
        print("[autonomous_blueprint] real platform matrix missing platforms object", file=sys.stderr)
        sys.exit(1)
    for platform in expected_platforms:
        entry = platforms.get(platform)
        if not isinstance(entry, dict):
            print(f"[autonomous_blueprint] real platform matrix missing platform entry: {platform}", file=sys.stderr)
            sys.exit(1)
        verification = entry.get("verification")
        if verification == "verified":
            if not entry.get("manifest_exists"):
                print(f"[autonomous_blueprint] platform verified without manifest: {platform}", file=sys.stderr)
                sys.exit(1)
            if entry.get("status") != "passed":
                print(
                    f"[autonomous_blueprint] verified platform manifest did not pass: {platform} status={entry.get('status')}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if entry.get("git_head") != summary.get("git_head"):
                print(f"[autonomous_blueprint] verified platform git_head mismatch: {platform}", file=sys.stderr)
                sys.exit(1)
            if entry.get("real_host_smoke") is not True:
                print(f"[autonomous_blueprint] verified platform is not real_host_smoke: {platform}", file=sys.stderr)
                sys.exit(1)
        elif verification not in {"missing", "invalid"}:
            print(
                f"[autonomous_blueprint] platform verification value is invalid: {platform}={verification}",
                file=sys.stderr,
            )
            sys.exit(1)
    if evidence.get("claim") == "verified":
        if evidence.get("status") != "passed" or evidence.get("full_matrix_verified") is not True:
            print(
                "[autonomous_blueprint] real platform matrix claimed verified without full pass",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        if evidence.get("status") == "passed" or evidence.get("full_matrix_verified") is True:
            print(
                "[autonomous_blueprint] real platform matrix status contradicts unverified claim",
                file=sys.stderr,
            )
            sys.exit(1)

def check_release_packaging(evidence):
    if evidence.get("status") not in {"passed", "partial"}:
        print(
            f"[autonomous_blueprint] release packaging status mismatch: actual={evidence.get('status')}",
            file=sys.stderr,
        )
        sys.exit(1)
    sdk = evidence.get("sdk")
    if not isinstance(sdk, dict) or sdk.get("package") != "genesis-sdk" or not sdk.get("version"):
        print("[autonomous_blueprint] release packaging evidence missing SDK version", file=sys.stderr)
        sys.exit(1)
    if sdk.get("shell_contract_epoch") != "genesis-sdk-shell-v1" or sdk.get("shell_abi_version") != 1:
        print("[autonomous_blueprint] release packaging SDK contract mismatch", file=sys.stderr)
        sys.exit(1)
    artifacts = evidence.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        print("[autonomous_blueprint] release packaging evidence missing artifact hashes", file=sys.stderr)
        sys.exit(1)
    artifact_kinds = {artifact.get("kind") for artifact in artifacts if isinstance(artifact, dict)}
    if "desktop_shell_binary" not in artifact_kinds:
        print("[autonomous_blueprint] release packaging evidence missing desktop shell binary artifact", file=sys.stderr)
        sys.exit(1)
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            print("[autonomous_blueprint] release packaging artifact entry must be an object", file=sys.stderr)
            sys.exit(1)
        if not artifact.get("path") or not artifact.get("sha256") or len(artifact.get("sha256", "")) != 64:
            print(
                f"[autonomous_blueprint] release packaging artifact hash is invalid: {artifact}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not isinstance(artifact.get("bytes"), int) or artifact.get("bytes") <= 0:
            print(
                f"[autonomous_blueprint] release packaging artifact size is invalid: {artifact}",
                file=sys.stderr,
            )
            sys.exit(1)
    platform_manifest = evidence.get("platform_manifest")
    if not isinstance(platform_manifest, dict):
        print("[autonomous_blueprint] release packaging evidence missing platform manifest link", file=sys.stderr)
        sys.exit(1)
    if platform_manifest.get("git_head") != summary.get("git_head"):
        print("[autonomous_blueprint] release packaging platform manifest git_head mismatch", file=sys.stderr)
        sys.exit(1)
    if platform_manifest.get("status") not in {"passed", "partial"} or platform_manifest.get("claim") not in {"verified", "unverified"}:
        print(
            "[autonomous_blueprint] release packaging platform manifest status is invalid: "
            f"{platform_manifest}",
            file=sys.stderr,
        )
        sys.exit(1)
    validation_profile = evidence.get("validation_profile")
    if not isinstance(validation_profile, dict):
        print("[autonomous_blueprint] release packaging evidence missing validation profile link", file=sys.stderr)
        sys.exit(1)
    if validation_profile.get("git_head") != summary.get("git_head") or validation_profile.get("status") != "passed":
        print(
            "[autonomous_blueprint] release packaging validation profile link mismatch: "
            f"{validation_profile}",
            file=sys.stderr,
        )
        sys.exit(1)
    expected_profile = {
        "fast": "default",
        "pilot": "pilot",
        "release": "release",
    }.get(summary.get("effective_mode"))
    if validation_profile.get("profile") != expected_profile:
        print(
            "[autonomous_blueprint] release packaging validation profile mismatch: "
            f"expected={expected_profile} actual={validation_profile.get('profile')}",
            file=sys.stderr,
        )
        sys.exit(1)
    requirements = evidence.get("requirements")
    if not isinstance(requirements, dict):
        print("[autonomous_blueprint] release packaging evidence missing requirements", file=sys.stderr)
        sys.exit(1)
    for requirement in (
        "artifact_hashes",
        "sdk_version",
        "sdk_contract_constants",
        "platform_manifest_link",
        "validation_profile_link",
        "desktop_package_smoke",
        "mobile_network_permission_documentation",
        "mobile_background_behavior_documentation",
    ):
        if requirements.get(requirement) != "passed":
            print(
                f"[autonomous_blueprint] release packaging hard requirement did not pass: {requirement}={requirements.get(requirement)}",
                file=sys.stderr,
            )
            sys.exit(1)
    if evidence.get("hard_links_passed") is not True:
        print("[autonomous_blueprint] release packaging hard links did not pass", file=sys.stderr)
        sys.exit(1)
    if evidence.get("release_complete") is True and evidence.get("status") != "passed":
        print("[autonomous_blueprint] release packaging complete evidence must have status=passed", file=sys.stderr)
        sys.exit(1)

if expected_status == "passed":
    for name in ("platform_contracts", "validation"):
        evidence = check_metadata(name, load_evidence(name))
        if evidence.get("status") != "passed":
            print(
                f"[autonomous_blueprint] evidence status mismatch: {name} expected=passed actual={evidence.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if name == "platform_contracts":
            check_platform_contracts(evidence)
        if name == "validation":
            check_validation_evidence(evidence)
    real_matrix = check_metadata("real_platform_matrix", load_evidence("real_platform_matrix"))
    if real_matrix.get("status") not in {"passed", "partial"}:
        print(
            f"[autonomous_blueprint] real platform matrix status mismatch: actual={real_matrix.get('status')}",
            file=sys.stderr,
        )
        sys.exit(1)
    check_real_platform_matrix(real_matrix)
    release_packaging = check_metadata("release_packaging", load_evidence("release_packaging"))
    check_release_packaging(release_packaging)
    if summary.get("mode") == "auto":
        release_precheck = check_metadata("release_precheck", load_evidence("release_precheck"))
        if release_precheck.get("status") not in {"passed", "blocked"}:
            print(
                f"[autonomous_blueprint] release precheck status mismatch: actual={release_precheck.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if summary.get("effective_mode") == "fast":
            if summary.get("reason") != "release_dirty_fast_fallback":
                print(
                    f"[autonomous_blueprint] auto fast fallback reason mismatch: actual={summary.get('reason')}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if release_precheck.get("status") != "blocked" or release_precheck.get("git_clean") is not False:
                print(
                    "[autonomous_blueprint] auto fast fallback requires blocked dirty release precheck: "
                    f"status={release_precheck.get('status')} git_clean={release_precheck.get('git_clean')}",
                    file=sys.stderr,
                )
                sys.exit(1)
            if not release_precheck.get("dirty_paths"):
                print("[autonomous_blueprint] dirty fast fallback requires dirty_paths evidence", file=sys.stderr)
                sys.exit(1)
        elif summary.get("effective_mode") == "release":
            if release_precheck.get("status") != "passed" or release_precheck.get("git_clean") is not True:
                print(
                    "[autonomous_blueprint] auto release requires clean release precheck: "
                    f"status={release_precheck.get('status')} git_clean={release_precheck.get('git_clean')}",
                    file=sys.stderr,
                )
                sys.exit(1)
elif expected_status == "blocked":
    if primary != "release_precheck":
        print(
            f"[autonomous_blueprint] blocked run must use release_precheck as primary evidence: actual={primary}",
            file=sys.stderr,
        )
        sys.exit(1)
    release_precheck = check_metadata("release_precheck", load_evidence("release_precheck"))
    if release_precheck.get("status") != "blocked":
        print(
            f"[autonomous_blueprint] blocked release precheck status mismatch: actual={release_precheck.get('status')}",
            file=sys.stderr,
        )
        sys.exit(1)
    if release_precheck.get("git_clean") is not False:
        print(
            f"[autonomous_blueprint] blocked release precheck must have git_clean=false: actual={release_precheck.get('git_clean')}",
            file=sys.stderr,
        )
        sys.exit(1)
    if not release_precheck.get("dirty_paths"):
        print("[autonomous_blueprint] blocked release precheck missing dirty_paths", file=sys.stderr)
        sys.exit(1)
elif expected_status == "failed":
    if primary == "platform_contracts":
        evidence = check_metadata("platform_contracts", load_evidence("platform_contracts"))
        if evidence.get("status") != "failed":
            print(
                f"[autonomous_blueprint] failed platform evidence status mismatch: actual={evidence.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not evidence.get("current_step") or not evidence.get("exit_code"):
            print("[autonomous_blueprint] failed platform evidence missing current_step or exit_code", file=sys.stderr)
            sys.exit(1)
        if not isinstance(evidence.get("target_matrix"), dict):
            print("[autonomous_blueprint] failed platform evidence missing target_matrix", file=sys.stderr)
            sys.exit(1)
    elif primary == "real_platform_matrix":
        evidence = check_metadata("real_platform_matrix", load_evidence("real_platform_matrix"))
        if evidence.get("status") != "failed":
            print(
                f"[autonomous_blueprint] failed real platform matrix status mismatch: actual={evidence.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        check_real_platform_matrix(evidence)
    elif primary == "release_packaging":
        evidence = check_metadata("release_packaging", load_evidence("release_packaging"))
        if evidence.get("status") != "failed":
            print(
                f"[autonomous_blueprint] failed release packaging status mismatch: actual={evidence.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not evidence.get("current_step") or not evidence.get("exit_code"):
            print("[autonomous_blueprint] failed release packaging evidence missing current_step or exit_code", file=sys.stderr)
            sys.exit(1)
    elif primary == "validation":
        evidence = check_metadata("validation", load_evidence("validation"))
        if evidence.get("status") != "failed":
            print(
                f"[autonomous_blueprint] failed validation evidence status mismatch: actual={evidence.get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        gate_report = evidence.get("gate_report")
        if not isinstance(gate_report, dict):
            print("[autonomous_blueprint] failed validation evidence missing gate_report", file=sys.stderr)
            sys.exit(1)
        failed_gate = evidence.get("failed_gate")
        if not failed_gate or evidence.get("current_step") != failed_gate:
            print(
                "[autonomous_blueprint] failed validation evidence has inconsistent failed_gate/current_step: "
                f"failed_gate={failed_gate} current_step={evidence.get('current_step')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if failed_gate in gate_report and gate_report[failed_gate].get("status") != "failed":
            print(
                "[autonomous_blueprint] failed validation gate_report does not mark failed gate: "
                f"{failed_gate}={gate_report[failed_gate].get('status')}",
                file=sys.stderr,
            )
            sys.exit(1)
        if not evidence.get("exit_code"):
            print("[autonomous_blueprint] failed validation evidence missing exit_code", file=sys.stderr)
            sys.exit(1)
    elif primary != "autonomous_summary":
        print(f"[autonomous_blueprint] failed run has unknown primary evidence: {primary}", file=sys.stderr)
        sys.exit(1)
PY
}

write_failed_summary() {
  local exit_code="$1"
  trap - ERR
  write_autonomous_summary "failed" "${CURRENT_STEP}_failed" "$exit_code" || true
  validate_autonomous_summary "failed" || true
  echo "[autonomous_blueprint] failed step=$CURRENT_STEP exit_code=$exit_code" >&2
  echo "[autonomous_blueprint] evidence=$EVIDENCE_DIR/autonomous-summary.json" >&2
  exit "$exit_code"
}

trap 'write_failed_summary "$?"' ERR

CURRENT_STEP="mode_selection"
if [[ "$MODE" == "auto" ]]; then
  write_release_precheck_manifest
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    MODE="fast"
    AUTONOMOUS_REASON="release_dirty_fast_fallback"
    echo "[autonomous_blueprint] auto selected fast because release precheck is blocked by dirty worktree" >&2
    echo "[autonomous_blueprint] release_precheck=$EVIDENCE_DIR/release-precheck.json" >&2
  else
    MODE="release"
    AUTONOMOUS_REASON="release_clean"
    echo "[autonomous_blueprint] auto selected release because worktree is clean"
  fi
fi

echo "[autonomous_blueprint] effective_mode=$MODE"

CURRENT_STEP="release_precheck"
if [[ "$MODE" == "release" ]]; then
  write_release_precheck_manifest
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "[autonomous_blueprint] release mode requires a clean worktree before expensive gates" >&2
    echo "[autonomous_blueprint] evidence=$EVIDENCE_DIR/release-precheck.json" >&2
    write_autonomous_summary "blocked" "git_clean_precheck"
    validate_autonomous_summary "blocked"
    git status --short >&2
    exit 3
  fi
fi

CURRENT_STEP="platform_contracts"
echo "[autonomous_blueprint] platform contracts"
GENESIS_PLATFORM_CONTRACT_EVIDENCE="$EVIDENCE_DIR/platform-contracts.json" \
  bash "$ROOT/scripts/validate_platform_contracts.sh"

CURRENT_STEP="real_platform_matrix"
echo "[autonomous_blueprint] real platform matrix"
GENESIS_PLATFORM_SMOKE_DIR="$EVIDENCE_DIR/platform-smoke" \
  bash "$ROOT/scripts/record_platform_smoke.sh"
GENESIS_PLATFORM_SMOKE_DIR="$EVIDENCE_DIR/platform-smoke" \
GENESIS_REAL_PLATFORM_MATRIX_EVIDENCE="$EVIDENCE_DIR/real-platform-matrix.json" \
GENESIS_REQUIRE_REAL_PLATFORM_MATRIX="${GENESIS_REQUIRE_REAL_PLATFORM_MATRIX:-0}" \
  bash "$ROOT/scripts/validate_real_platform_matrix.sh"

CURRENT_STEP="core_shell_clippy"
echo "[autonomous_blueprint] core shell clippy"
cargo clippy -p genesis-core --no-default-features -- -D warnings

CURRENT_STEP="validation"
echo "[autonomous_blueprint] default validation"
case "$MODE" in
  fast)
    RUN_JAVA_PROBE=0 \
    RUN_JAVA_DEPENDENCY_SCAN=0 \
    RUN_LOCAL_LM_SMOKE=0 \
    RUN_LAZARUS_STRESS=0 \
    RUN_PLATFORM_CONTRACTS=1 \
    GENESIS_PLATFORM_CONTRACTS_PRECHECKED=1 \
    GENESIS_VALIDATE_PROFILE=default \
    GENESIS_VALIDATE_EVIDENCE="$EVIDENCE_DIR/validation-fast.json" \
      bash "$ROOT/scripts/validate_all.sh"
    ;;
  pilot)
    RUN_JAVA_PROBE="${RUN_JAVA_PROBE:-0}" \
    RUN_JAVA_DEPENDENCY_SCAN="${RUN_JAVA_DEPENDENCY_SCAN:-0}" \
    RUN_LOCAL_LM_SMOKE="${RUN_LOCAL_LM_SMOKE:-0}" \
    RUN_PLATFORM_CONTRACTS=1 \
    GENESIS_PLATFORM_CONTRACTS_PRECHECKED=1 \
    GENESIS_VALIDATE_PROFILE=pilot \
    GENESIS_VALIDATE_EVIDENCE="$EVIDENCE_DIR/validation-pilot.json" \
      bash "$ROOT/scripts/validate_all.sh"
    ;;
  release)
    RUN_PLATFORM_CONTRACTS=1 \
    GENESIS_PLATFORM_CONTRACTS_PRECHECKED=1 \
    GENESIS_VALIDATE_PROFILE=release \
    GENESIS_VALIDATE_EVIDENCE="$EVIDENCE_DIR/validation-release.json" \
      bash "$ROOT/scripts/validate_all.sh"
    ;;
esac

case "$MODE" in
  fast)
    VALIDATION_EVIDENCE_FILE="validation-fast.json"
    ;;
  pilot)
    VALIDATION_EVIDENCE_FILE="validation-pilot.json"
    ;;
  release)
    VALIDATION_EVIDENCE_FILE="validation-release.json"
    ;;
esac

CURRENT_STEP="release_packaging"
echo "[autonomous_blueprint] release packaging evidence"
GENESIS_RELEASE_PACKAGING_EVIDENCE="$EVIDENCE_DIR/release-packaging.json" \
GENESIS_RELEASE_PLATFORM_MATRIX_EVIDENCE="$EVIDENCE_DIR/real-platform-matrix.json" \
GENESIS_RELEASE_VALIDATION_EVIDENCE="$EVIDENCE_DIR/$VALIDATION_EVIDENCE_FILE" \
GENESIS_REQUIRE_RELEASE_PACKAGING="${GENESIS_REQUIRE_RELEASE_PACKAGING:-0}" \
  bash "$ROOT/scripts/record_release_packaging_evidence.sh"

CURRENT_STEP="diff_whitespace"
echo "[autonomous_blueprint] diff whitespace"
git diff --check

CURRENT_STEP="summary"
write_autonomous_summary "passed" "$AUTONOMOUS_REASON"
CURRENT_STEP="summary_validation"
validate_autonomous_summary "passed"
echo "[autonomous_blueprint] evidence=$EVIDENCE_DIR"
echo "[autonomous_blueprint] ok"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_STEP="init"
TARGET_MATRIX_EVENTS=()
CONTAINMENT_REPORT_PATH="$(mktemp "${TMPDIR:-/tmp}/genesis-platform-containment.XXXXXX")"
cd "$ROOT"

if [[ -n "${RUSTFLAGS:-}" ]]; then
  export RUSTFLAGS="$RUSTFLAGS -D warnings"
else
  export RUSTFLAGS="-D warnings"
fi

PACKAGES=(
  genesis-platform
  genesis-sdk
  brain-llm
  genesis-replay
  genesis-os-driver
  genesis-frame-grabber
)
CARGO_PACKAGE_ARGS=()
for package in "${PACKAGES[@]}"; do
  CARGO_PACKAGE_ARGS+=("-p" "$package")
done

write_platform_contract_manifest() {
  local status="$1"
  local exit_code="${2:-}"
  local reason="${3:-}"
  if [[ -z "${GENESIS_PLATFORM_CONTRACT_EVIDENCE:-}" ]]; then
    return 0
  fi
  local matrix_events_payload=""
  if [[ "${#TARGET_MATRIX_EVENTS[@]}" -gt 0 ]]; then
    printf -v matrix_events_payload '%s\n' "${TARGET_MATRIX_EVENTS[@]}"
  fi
  GENESIS_PLATFORM_CONTRACT_MATRIX_EVENTS="$matrix_events_payload" GENESIS_PLATFORM_CONTAINMENT_REPORT="$CONTAINMENT_REPORT_PATH" python3 - "$GENESIS_PLATFORM_CONTRACT_EVIDENCE" "$status" "$exit_code" "$reason" "$CURRENT_STEP" "$ROOT" "${TARGETS[@]}" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import os
import subprocess
import sys

path = Path(sys.argv[1])
status = sys.argv[2]
exit_code = sys.argv[3]
reason = sys.argv[4]
current_step = sys.argv[5]
root = Path(sys.argv[6])
targets = sys.argv[7:]
matrix_events = [
    event
    for event in os.environ.get("GENESIS_PLATFORM_CONTRACT_MATRIX_EVENTS", "").splitlines()
    if event
]

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

target_matrix = {
    target: {
        "workspace": "unknown",
        "genesis_core_shell": "unknown",
        "genesis_replay_shell": "unknown",
    }
    for target in targets
}
valid_checks = {"workspace", "genesis_core_shell", "genesis_replay_shell"}
for event in matrix_events:
    try:
        target, check_name, check_status = event.split("|", 2)
    except ValueError:
        continue
    if target in target_matrix and check_name in valid_checks:
        target_matrix[target][check_name] = check_status

containment_report = None
containment_report_path = os.environ.get("GENESIS_PLATFORM_CONTAINMENT_REPORT")
if containment_report_path and Path(containment_report_path).exists():
    try:
        containment_report = json.loads(Path(containment_report_path).read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        containment_report = None

def containment_status(check_name):
    if isinstance(containment_report, dict):
        return containment_report.get("checks", {}).get(check_name, {}).get("status", "unknown")
    return "passed" if status == "passed" else "unknown"

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "targets": targets,
    "target_matrix": target_matrix,
    "packages": [
        "genesis-platform",
        "genesis-sdk",
        "brain-llm",
        "genesis-replay",
        "genesis-os-driver",
        "genesis-frame-grabber",
    ],
    "core_shell": {
        "package": "genesis-core",
        "features": "--no-default-features",
    },
    "replay_shell": {
        "package": "genesis-replay",
        "features": "--no-default-features",
    },
    "containment_report": containment_report,
    "platform_api_containment": containment_status("platform_api_containment"),
    "python_transport_containment": containment_status("python_transport_containment"),
    "platform_identity_containment": containment_status("platform_identity_containment"),
    "local_service_path_containment": containment_status("local_service_path_containment"),
    "network_transport_containment": containment_status("network_transport_containment"),
    "plugin_fs_containment": containment_status("plugin_fs_containment"),
    "process_cwd_containment": containment_status("process_cwd_containment"),
    "runtime_temp_dir_containment": containment_status("runtime_temp_dir_containment"),
    "subprocess_containment": containment_status("subprocess_containment"),
    "warnings_as_errors": True,
}
if status != "passed":
    manifest["current_step"] = current_step
    manifest["reason"] = reason
    if exit_code:
        manifest["exit_code"] = int(exit_code)

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_failed_manifest() {
  local exit_code="$1"
  trap - ERR
  write_platform_contract_manifest "failed" "$exit_code" "${CURRENT_STEP}_failed" || true
  if [[ -n "${GENESIS_PLATFORM_CONTRACT_EVIDENCE:-}" ]]; then
    echo "[platform_contracts] evidence=$GENESIS_PLATFORM_CONTRACT_EVIDENCE" >&2
  fi
  exit "$exit_code"
}

trap 'write_failed_manifest "$?"' ERR

record_target_check() {
  local target="$1"
  local check_name="$2"
  TARGET_MATRIX_EVENTS+=("${target}|${check_name}|passed")
}

if [[ -n "${GENESIS_PLATFORM_TARGETS:-}" ]]; then
  read -r -a TARGETS <<< "$GENESIS_PLATFORM_TARGETS"
else
  TARGETS=(
    aarch64-apple-darwin
    x86_64-unknown-linux-gnu
    x86_64-pc-windows-msvc
    aarch64-apple-ios
    aarch64-linux-android
    wasm32-wasip1
  )
fi

echo "[platform_contracts] checking target contracts"
for target in "${TARGETS[@]}"; do
  CURRENT_STEP="target:${target}:workspace"
  echo "[platform_contracts] cargo check target=$target"
  cargo check "${CARGO_PACKAGE_ARGS[@]}" --target "$target"
  record_target_check "$target" "workspace"
  CURRENT_STEP="target:${target}:genesis-core-shell"
  echo "[platform_contracts] cargo check genesis-core shell target=$target"
  cargo check -p genesis-core --no-default-features --target "$target"
  record_target_check "$target" "genesis_core_shell"
  CURRENT_STEP="target:${target}:genesis-replay-shell"
  echo "[platform_contracts] cargo check genesis-replay shell target=$target"
  cargo check -p genesis-replay --no-default-features --target "$target"
  record_target_check "$target" "genesis_replay_shell"
done

CURRENT_STEP="containment_scan"
echo "[platform_contracts] scanning platform API containment"
GENESIS_PLATFORM_CONTAINMENT_REPORT="$CONTAINMENT_REPORT_PATH" python3 - <<'PY'
from pathlib import Path
import json
import os
import re
import sys

roots = [
    Path("genesis-core"),
    Path("genesis-sdk"),
    Path("genesis-platform"),
    Path("genesis-plugins"),
    Path("genesis-daemons"),
    Path("genesis-drivers"),
    Path("genesis-replay"),
]

report = {
    "roots": [str(root) for root in roots],
    "checks": {},
}

def finish_check(name, allowed_paths, violations):
    report["checks"][name] = {
        "status": "passed" if not violations else "failed",
        "allowed_paths": [str(path) for path in sorted(allowed_paths, key=str)],
        "violation_count": len(violations),
    }

def fail_if_needed():
    report_path = os.environ.get("GENESIS_PLATFORM_CONTAINMENT_REPORT")
    if report_path:
        Path(report_path).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    failed = [
        name
        for name, check in report["checks"].items()
        if check.get("status") != "passed"
    ]
    if failed:
        print(
            f"[platform_contracts] containment scan failed: {', '.join(failed)}",
            file=sys.stderr,
        )
        sys.exit(1)

def skip_scanned_file(path):
    return not path.is_file() or "target" in path.parts or "tests" in path.parts

allowed = {
    Path("genesis-platform/Cargo.toml"),
    Path("genesis-platform/src/desktop/unix_socket.rs"),
    Path("genesis-platform/src/desktop/windows_pipe.rs"),
}
pattern = re.compile(
    r"std::os::unix|socket2|windows_sys|CreateNamedPipe|ConnectNamedPipe|"
    r"WaitNamedPipe|UnixListener|UnixStream"
)

violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path in allowed:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for index, line in enumerate(text.splitlines(), start=1):
            if pattern.search(line):
                violations.append(f"{path}:{index}: {line.strip()}")

if violations:
    print("[platform_contracts] platform API leaked outside adapter boundary", file=sys.stderr)
    for violation in violations:
        print(violation, file=sys.stderr)
finish_check("platform_api_containment", allowed, violations)

python_transport_allowed_files = {
    Path("genesis-daemons/daemon_transport.py"),
}
python_transport_pattern = re.compile(
    r"socket\.socket\(|socket\.AF_UNIX|socketserver|ThreadingTCPServer|"
    r"BaseHTTPRequestHandler|BoundedTCPServer"
)
python_transport_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".py":
            continue
        if path in python_transport_allowed_files:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for index, line in enumerate(text.splitlines(), start=1):
            if python_transport_pattern.search(line):
                python_transport_violations.append(f"{path}:{index}: {line.strip()}")

if python_transport_violations:
    print("[platform_contracts] Python transport API leaked outside daemon_transport", file=sys.stderr)
    for violation in python_transport_violations:
        print(violation, file=sys.stderr)
finish_check("python_transport_containment", python_transport_allowed_files, python_transport_violations)

platform_identity_allowed_roots = {
    Path("genesis-platform"),
}
platform_identity_allowed_files = {
    Path("genesis-drivers/os-driver/src/lib.rs"),
    Path("genesis-drivers/frame-grabber/src/main.rs"),
}
platform_identity_pattern = re.compile(
    r"target_os|cfg!\(target_os|std::env::consts::OS"
)

def strip_cfg_test_modules(text):
    output = []
    pending_cfg_test = False
    skipping = False
    depth = 0

    for line in text.splitlines():
        stripped = line.strip()
        if not skipping and stripped == "#[cfg(test)]":
            pending_cfg_test = True
            output.append("")
            continue

        if not skipping and pending_cfg_test and stripped.startswith("mod ") and "{" in stripped:
            skipping = True
            depth = line.count("{") - line.count("}")
            pending_cfg_test = False
            output.append("")
            if depth <= 0:
                skipping = False
            continue

        if skipping:
            depth += line.count("{") - line.count("}")
            output.append("")
            if depth <= 0:
                skipping = False
            continue

        pending_cfg_test = False
        output.append(line)

    return "\n".join(output)

identity_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix not in {".rs", ".toml"}:
            continue
        if path in platform_identity_allowed_files:
            continue
        if any(path == allowed_root or allowed_root in path.parents for allowed_root in platform_identity_allowed_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if platform_identity_pattern.search(line):
                identity_violations.append(f"{path}:{index}: {line.strip()}")

if identity_violations:
    print("[platform_contracts] platform identity leaked outside adapter/driver boundary", file=sys.stderr)
    for violation in identity_violations:
        print(violation, file=sys.stderr)
finish_check(
    "platform_identity_containment",
    platform_identity_allowed_roots | platform_identity_allowed_files,
    identity_violations,
)

adapter_allowed_roots = {
    Path("genesis-platform"),
}

runtime_temp_pattern = re.compile(r"std::env::temp_dir\(")
runtime_temp_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".rs":
            continue
        if any(path == allowed_root or allowed_root in path.parents for allowed_root in adapter_allowed_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if runtime_temp_pattern.search(line):
                runtime_temp_violations.append(f"{path}:{index}: {line.strip()}")

if runtime_temp_violations:
    print("[platform_contracts] runtime temp dir access leaked outside platform adapter", file=sys.stderr)
    for violation in runtime_temp_violations:
        print(violation, file=sys.stderr)
finish_check("runtime_temp_dir_containment", adapter_allowed_roots, runtime_temp_violations)

subprocess_pattern = re.compile(r"\bstd::process::Command\b|\bCommand::new\(")
subprocess_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".rs":
            continue
        if any(path == allowed_root or allowed_root in path.parents for allowed_root in adapter_allowed_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if subprocess_pattern.search(line):
                subprocess_violations.append(f"{path}:{index}: {line.strip()}")

if subprocess_violations:
    print("[platform_contracts] subprocess spawning leaked outside platform adapter", file=sys.stderr)
    for violation in subprocess_violations:
        print(violation, file=sys.stderr)
finish_check("subprocess_containment", adapter_allowed_roots, subprocess_violations)

network_transport_allowed_files = {
    Path("genesis-platform/src/desktop/loopback_http.rs"),
    Path("genesis-platform/src/desktop/loopback_tcp.rs"),
    Path("genesis-platform/src/remote_http.rs"),
}
network_transport_pattern = re.compile(
    r"\bstd::net\b|\bTcpStream\b|\bTcpListener\b|\bToSocketAddrs\b"
)
network_transport_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".rs":
            continue
        if path in network_transport_allowed_files:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if network_transport_pattern.search(line):
                network_transport_violations.append(f"{path}:{index}: {line.strip()}")

if network_transport_violations:
    print("[platform_contracts] network transport leaked outside platform adapter", file=sys.stderr)
    for violation in network_transport_violations:
        print(violation, file=sys.stderr)
finish_check(
    "network_transport_containment",
    network_transport_allowed_files,
    network_transport_violations,
)

plugin_fs_allowed_roots = {
    Path("genesis-platform"),
}
plugin_fs_pattern = re.compile(
    r"std::env::current_dir\(|fs::read_dir\(|fs::read\(|fs::copy\(|"
    r"File::open\(|use std::fs::File"
)
plugin_fs_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".rs":
            continue
        if any(path == allowed_root or allowed_root in path.parents for allowed_root in plugin_fs_allowed_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if plugin_fs_pattern.search(line):
                plugin_fs_violations.append(f"{path}:{index}: {line.strip()}")

if plugin_fs_violations:
    print("[platform_contracts] plugin filesystem discovery/read leaked outside platform adapter", file=sys.stderr)
    for violation in plugin_fs_violations:
        print(violation, file=sys.stderr)
finish_check("plugin_fs_containment", plugin_fs_allowed_roots, plugin_fs_violations)

process_cwd_allowed_roots = {
    Path("genesis-platform"),
}
process_cwd_pattern = re.compile(r"std::env::set_current_dir\(")
process_cwd_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix != ".rs":
            continue
        if any(path == allowed_root or allowed_root in path.parents for allowed_root in process_cwd_allowed_roots):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text)
        for index, line in enumerate(production_text.splitlines(), start=1):
            if process_cwd_pattern.search(line):
                process_cwd_violations.append(f"{path}:{index}: {line.strip()}")

if process_cwd_violations:
    print("[platform_contracts] process current-directory mutation leaked outside platform adapter", file=sys.stderr)
    for violation in process_cwd_violations:
        print(violation, file=sys.stderr)
finish_check("process_cwd_containment", process_cwd_allowed_roots, process_cwd_violations)

local_service_path_allowed_files = {
    Path("genesis-platform/src/ipc.rs"),
    Path("genesis-daemons/daemon_transport.py"),
}
local_service_path_pattern = re.compile(
    r"/tmp/genesis|PathBuf::from\(\"/tmp|"
    r"genesis_(brain|act|dynamic_act|os_driver|vision_daemon)\.sock"
)

path_violations = []
for root in roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if skip_scanned_file(path):
            continue
        if path.suffix not in {".rs", ".py"}:
            continue
        if path in local_service_path_allowed_files:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        production_text = strip_cfg_test_modules(text) if path.suffix == ".rs" else text
        for index, line in enumerate(production_text.splitlines(), start=1):
            if local_service_path_pattern.search(line):
                path_violations.append(f"{path}:{index}: {line.strip()}")

if path_violations:
    print("[platform_contracts] local service path leaked outside resolver boundary", file=sys.stderr)
    for violation in path_violations:
        print(violation, file=sys.stderr)
finish_check("local_service_path_containment", local_service_path_allowed_files, path_violations)
fail_if_needed()
PY

if [[ -n "${GENESIS_PLATFORM_CONTRACT_EVIDENCE:-}" ]]; then
  CURRENT_STEP="success_manifest"
  write_platform_contract_manifest "passed"
  echo "[platform_contracts] evidence=$GENESIS_PLATFORM_CONTRACT_EVIDENCE"
fi

echo "[platform_contracts] ok"

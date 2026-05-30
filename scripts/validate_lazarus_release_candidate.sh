#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STARTED_AT_MS="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_ROOT="${LAZARUS_RELEASE_EVIDENCE_ROOT:-$ROOT/target/lazarus-release-evidence}"
EVIDENCE_DIR="${LAZARUS_RELEASE_EVIDENCE_DIR:-$EVIDENCE_ROOT/$STAMP}"
LOG_PATH="$EVIDENCE_DIR/validate.log"
MANIFEST_PATH="$EVIDENCE_DIR/manifest.json"

mkdir -p "$EVIDENCE_DIR"
touch "$LOG_PATH"

write_failure_manifest() {
  local reason="$1"
  local exit_code="$2"
  local finished_at_ms
  finished_at_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  python3 - "$ROOT" "$MANIFEST_PATH" "$LOG_PATH" "$STARTED_AT_MS" "$finished_at_ms" "$reason" "$exit_code" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])
started_at_ms = int(sys.argv[4])
finished_at_ms = int(sys.argv[5])
reason = sys.argv[6]
exit_code = int(sys.argv[7])

def git(*args):
    return subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    ).stdout.strip()

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def display_path(path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)

manifest = {
    "schema_version": 1,
    "event": "lazarus_release_candidate_validation",
    "status": "failed",
    "failure_reason": reason,
    "exit_code": exit_code,
    "created_at_unix_ms": finished_at_ms,
    "started_at_unix_ms": started_at_ms,
    "duration_ms": finished_at_ms - started_at_ms,
    "git": {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("branch", "--show-current"),
        "describe": git("describe", "--tags", "--always", "--dirty"),
    },
    "profile": "release",
    "checks": {
        "java_probe_requested": os.environ.get("RUN_JAVA_PROBE") == "1",
        "java_dependency_cve_scan_requested": os.environ.get("RUN_JAVA_DEPENDENCY_SCAN") == "1",
        "local_lm_synthesis_smoke_requested": os.environ.get("RUN_LOCAL_LM_SMOKE") == "1",
        "lazarus_lifecycle_stress_requested": os.environ.get("RUN_LAZARUS_STRESS") == "1",
        "git_clean_precheck_requested": os.environ.get("CHECK_GIT_CLEAN") == "1",
    },
    "inputs": {
        "lazarus_stress_iterations": os.environ.get("LAZARUS_STRESS_ITERATIONS"),
        "lazarus_lm_model": os.environ.get("LAZARUS_LM_MODEL"),
        "lazarus_lm_endpoint_set": bool(os.environ.get("LAZARUS_LM_ENDPOINT")),
        "nvd_api_key_set": bool(os.environ.get("NVD_API_KEY")),
    },
    "artifacts": [
        {
            "path": display_path(log_path),
            "sha256": sha256(log_path),
            "bytes": log_path.stat().st_size,
        }
    ],
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

finalize_failure_manifest() {
  local exit_code="$?"
  if [ "$exit_code" -ne 0 ] && [ ! -s "$MANIFEST_PATH" ]; then
    write_failure_manifest "command_failed" "$exit_code"
    echo "[release_candidate] failure_manifest=$MANIFEST_PATH" >&2
  fi
}

trap finalize_failure_manifest EXIT

export GENESIS_VALIDATE_PROFILE=release
export GENESIS_RUNTIME_PROFILE=release
export RUN_JAVA_PROBE="${RUN_JAVA_PROBE:-1}"
export RUN_JAVA_DEPENDENCY_SCAN="${RUN_JAVA_DEPENDENCY_SCAN:-1}"
export RUN_LOCAL_LM_SMOKE="${RUN_LOCAL_LM_SMOKE:-1}"
export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-100}"
export CHECK_GIT_CLEAN="${CHECK_GIT_CLEAN:-1}"
export LAZARUS_LM_OUT_DIR="${LAZARUS_LM_OUT_DIR:-$EVIDENCE_DIR/local-lm-synthesis}"
export LAZARUS_ORACLE_LOG_DIR="${LAZARUS_ORACLE_LOG_DIR:-$EVIDENCE_DIR/local-lm-synthesis/oracle-logs}"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    local reason="${name} is required for strict release validation"
    echo "[release_candidate] ${reason}" | tee -a "$LOG_PATH" >&2
    write_failure_manifest "missing_required_env:${name}" 2
    echo "[release_candidate] failure_manifest=$MANIFEST_PATH" >&2
    exit 2
  fi
}

if [ "$RUN_JAVA_DEPENDENCY_SCAN" = "1" ]; then
  require_env NVD_API_KEY
fi

if [ "$RUN_LOCAL_LM_SMOKE" = "1" ]; then
  require_env LAZARUS_LM_ENDPOINT
  require_env LAZARUS_LM_MODEL
fi

if [ "$RUN_LAZARUS_STRESS" = "1" ] && [ "$LAZARUS_STRESS_ITERATIONS" -lt 100 ]; then
  echo "[release_candidate] LAZARUS_STRESS_ITERATIONS must be >= 100 for strict release validation" | tee -a "$LOG_PATH" >&2
  write_failure_manifest "invalid_lazarus_stress_iterations" 2
  echo "[release_candidate] failure_manifest=$MANIFEST_PATH" >&2
  exit 2
fi

bash "$ROOT/scripts/validate_all.sh" 2>&1 | tee "$LOG_PATH"

FINISHED_AT_MS="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

python3 - "$ROOT" "$MANIFEST_PATH" "$LOG_PATH" "$STARTED_AT_MS" "$FINISHED_AT_MS" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])
started_at_ms = int(sys.argv[4])
finished_at_ms = int(sys.argv[5])

def git(*args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def display_path(path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)

manifest = {
    "schema_version": 1,
    "event": "lazarus_release_candidate_validation",
    "status": "passed",
    "created_at_unix_ms": finished_at_ms,
    "started_at_unix_ms": started_at_ms,
    "duration_ms": finished_at_ms - started_at_ms,
    "git": {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("branch", "--show-current"),
        "describe": subprocess.run(
            ["git", "describe", "--tags", "--always", "--dirty"],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        ).stdout.strip(),
    },
    "profile": "release",
    "checks": {
        "rust_workspace_tests": True,
        "rust_clippy_deny_warnings": True,
        "python_bytecode_compile": True,
        "java_probe": os.environ.get("RUN_JAVA_PROBE") == "1",
        "java_dependency_cve_scan": os.environ.get("RUN_JAVA_DEPENDENCY_SCAN") == "1",
        "local_lm_synthesis_smoke": os.environ.get("RUN_LOCAL_LM_SMOKE") == "1",
        "lazarus_lifecycle_stress": os.environ.get("RUN_LAZARUS_STRESS") == "1",
        "git_clean_precheck": os.environ.get("CHECK_GIT_CLEAN") == "1",
    },
    "inputs": {
        "lazarus_stress_iterations": os.environ.get("LAZARUS_STRESS_ITERATIONS"),
        "lazarus_lm_model": os.environ.get("LAZARUS_LM_MODEL"),
        "lazarus_lm_endpoint_set": bool(os.environ.get("LAZARUS_LM_ENDPOINT")),
        "nvd_api_key_set": bool(os.environ.get("NVD_API_KEY")),
    },
    "artifacts": [
        {
            "path": display_path(log_path),
            "sha256": sha256(log_path),
            "bytes": log_path.stat().st_size,
        }
    ],
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"[release_candidate] evidence_manifest={manifest_path}")
PY

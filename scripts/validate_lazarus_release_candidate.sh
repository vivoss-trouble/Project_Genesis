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

export GENESIS_VALIDATE_PROFILE=release
export RUN_JAVA_PROBE="${RUN_JAVA_PROBE:-1}"
export RUN_JAVA_DEPENDENCY_SCAN="${RUN_JAVA_DEPENDENCY_SCAN:-1}"
export RUN_LOCAL_LM_SMOKE="${RUN_LOCAL_LM_SMOKE:-1}"
export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-100}"
export CHECK_GIT_CLEAN="${CHECK_GIT_CLEAN:-1}"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "[release_candidate] ${name} is required for strict release validation" >&2
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
  echo "[release_candidate] LAZARUS_STRESS_ITERATIONS must be >= 100 for strict release validation" >&2
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
            "path": str(log_path.relative_to(root)),
            "sha256": sha256(log_path),
            "bytes": log_path.stat().st_size,
        }
    ],
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"[release_candidate] evidence_manifest={manifest_path}")
PY

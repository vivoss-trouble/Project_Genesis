#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$ROOT/config/reasoning-engine.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/config/reasoning-engine.env"
  set +a
fi

PROFILE="${GENESIS_VALIDATE_PROFILE:-default}"
EVIDENCE_PATH="${GENESIS_VALIDATE_EVIDENCE:-$ROOT/.genesis-state/validation-evidence-${PROFILE}.json}"
CURRENT_STEP="init"
GATE_RESULTS=()

write_invalid_profile_manifest() {
  python3 - "$EVIDENCE_PATH" "$PROFILE" "$ROOT" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
profile = sys.argv[2]
root = Path(sys.argv[3])
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
gates = [
    "rust_tests",
    "rust_clippy",
    "python_bytecode_compile",
    "python_daemon_transport_selftest",
    "java_probe",
    "java_dependency_scan",
    "local_lm_smoke",
    "lazarus_stress",
    "platform_contracts",
]
gate_report = {
    gate: {
        "status": "not_run",
        "required": gate in {"rust_tests", "rust_clippy", "python_bytecode_compile", "python_daemon_transport_selftest"},
        "skip_reason": "",
    }
    for gate in gates
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "profile": profile,
    "status": "failed",
    "failed_gate": "profile_validation",
    "current_step": "profile_validation",
    "exit_code": 2,
    "reason": "invalid_profile",
    "gate_report": gate_report,
    **{gate: "not_run" for gate in gates},
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

case "$PROFILE" in
  default|pilot|release)
    ;;
  *)
    echo "[validate_all] invalid GENESIS_VALIDATE_PROFILE=$PROFILE; expected default, pilot, or release" >&2
    write_invalid_profile_manifest
    echo "[validate_all] evidence=$EVIDENCE_PATH" >&2
    exit 2
    ;;
esac

if [ "$PROFILE" = "pilot" ]; then
  export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
  export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-20}"
fi

if [ "$PROFILE" = "release" ]; then
  export RUN_JAVA_DEPENDENCY_SCAN="${RUN_JAVA_DEPENDENCY_SCAN:-1}"
  export RUN_LOCAL_LM_SMOKE="${RUN_LOCAL_LM_SMOKE:-1}"
  export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
  export RUN_PLATFORM_CONTRACTS="${RUN_PLATFORM_CONTRACTS:-1}"
  export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-100}"
  export CHECK_GIT_CLEAN="${CHECK_GIT_CLEAN:-1}"
fi

cd "$ROOT"

echo "[validate_all] profile=$PROFILE"

platform_contract_status() {
  if [ "${RUN_PLATFORM_CONTRACTS:-0}" = "1" ]; then
    echo "passed"
  else
    echo "skipped"
  fi
}

platform_contract_skip_reason() {
  if [ "${RUN_PLATFORM_CONTRACTS:-0}" != "1" ]; then
    echo "RUN_PLATFORM_CONTRACTS=0"
  else
    echo ""
  fi
}

set_gate_result() {
  local gate="$1"
  local status="$2"
  GATE_RESULTS+=("${gate}=${status}")
}

write_success_manifest() {
  python3 - "$EVIDENCE_PATH" "$PROFILE" "$ROOT" ${GATE_RESULTS[@]+"${GATE_RESULTS[@]}"} <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import os
import subprocess
import sys

path = Path(sys.argv[1])
profile = sys.argv[2]
root = Path(sys.argv[3])
gate_results = {}
for raw in sys.argv[4:]:
    if "=" in raw:
        gate, status = raw.split("=", 1)
        gate_results[gate] = status

def env_enabled(name, default):
    return os.environ.get(name, default) == "1"

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

base_gates = (
    "rust_tests",
    "rust_clippy",
    "python_bytecode_compile",
    "python_daemon_transport_selftest",
)
optional_gates = {
    "java_probe": ("RUN_JAVA_PROBE", "1"),
    "java_dependency_scan": ("RUN_JAVA_DEPENDENCY_SCAN", "0"),
    "local_lm_smoke": ("RUN_LOCAL_LM_SMOKE", "0"),
    "lazarus_stress": ("RUN_LAZARUS_STRESS", "0"),
    "platform_contracts": ("RUN_PLATFORM_CONTRACTS", "0"),
}
all_gates = (*base_gates, *optional_gates.keys())
gate_report = {}
for gate in base_gates:
    actual = gate_results.get(gate)
    if actual != "passed":
        print(f"[validate_all] success manifest refusing missing/non-passed gate result: {gate}={actual}", file=sys.stderr)
        sys.exit(1)
    gate_report[gate] = {"status": actual, "required": True}
for gate, (env_name, default) in optional_gates.items():
    enabled = env_enabled(env_name, default)
    actual = gate_results.get(gate)
    expected = "passed" if enabled else "skipped"
    if actual != expected:
        print(
            f"[validate_all] success manifest gate result mismatch: gate={gate} expected={expected} actual={actual}",
            file=sys.stderr,
        )
        sys.exit(1)
    gate_report[gate] = {
        "status": actual,
        "required": enabled,
        "skip_reason": "" if enabled else f"{env_name}=0",
    }
if gate_report["platform_contracts"]["status"] == "passed":
    gate_report["platform_contracts"]["skip_reason"] = ""

manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "profile": profile,
    "status": "passed",
    "gate_report": gate_report,
    **{gate: gate_report[gate]["status"] for gate in all_gates},
    "skip_reasons": {
        gate: report.get("skip_reason", "")
        for gate, report in gate_report.items()
        if gate not in {"rust_tests", "rust_clippy", "python_bytecode_compile", "python_daemon_transport_selftest"}
    },
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_failure_manifest() {
  local exit_code="$1"
  local reason="${2:-${CURRENT_STEP}_failed}"
  python3 - "$EVIDENCE_PATH" "$PROFILE" "$CURRENT_STEP" "$exit_code" "$reason" "$ROOT" ${GATE_RESULTS[@]+"${GATE_RESULTS[@]}"} <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import os
import subprocess
import sys

path = Path(sys.argv[1])
profile = sys.argv[2]
current_step = sys.argv[3]
exit_code = int(sys.argv[4])
reason = sys.argv[5]
root = Path(sys.argv[6])
gate_results = {}
for raw in sys.argv[7:]:
    if "=" in raw:
        gate, status = raw.split("=", 1)
        gate_results[gate] = status
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
gates = [
    "rust_tests",
    "rust_clippy",
    "python_bytecode_compile",
    "python_daemon_transport_selftest",
    "java_probe",
    "java_dependency_scan",
    "local_lm_smoke",
    "lazarus_stress",
    "platform_contracts",
]
required_base = {
    "rust_tests",
    "rust_clippy",
    "python_bytecode_compile",
    "python_daemon_transport_selftest",
}
optional_env = {
    "java_probe": ("RUN_JAVA_PROBE", "1"),
    "java_dependency_scan": ("RUN_JAVA_DEPENDENCY_SCAN", "0"),
    "local_lm_smoke": ("RUN_LOCAL_LM_SMOKE", "0"),
    "lazarus_stress": ("RUN_LAZARUS_STRESS", "0"),
    "platform_contracts": ("RUN_PLATFORM_CONTRACTS", "0"),
}
gate_report = {}
for gate in gates:
    if gate == current_step:
        status = "failed"
    else:
        status = gate_results.get(gate, "unknown")
    entry = {"status": status, "required": gate in required_base, "skip_reason": ""}
    if gate in optional_env:
        env_name, default = optional_env[gate]
        enabled = os.environ.get(env_name, default) == "1"
        entry["required"] = enabled
        if status == "skipped":
            entry["skip_reason"] = f"{env_name}=0" if not enabled else "skipped_after_required_gate_enabled"
    gate_report[gate] = entry
manifest = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "profile": profile,
    "status": "failed",
    "failed_gate": current_step,
    "current_step": current_step,
    "exit_code": exit_code,
    "reason": reason,
    "gate_report": gate_report,
}
for gate in gates:
    manifest[gate] = gate_report[gate]["status"]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

fail_current_step() {
  local exit_code="${1:-1}"
  local reason="${2:-${CURRENT_STEP}_failed}"
  trap - ERR
  write_failure_manifest "$exit_code" "$reason" || true
  echo "[validate_all] failed step=$CURRENT_STEP exit_code=$exit_code" >&2
  echo "[validate_all] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

write_failure_on_error() {
  local exit_code="$1"
  trap - ERR
  write_failure_manifest "$exit_code" "${CURRENT_STEP}_failed" || true
  echo "[validate_all] failed step=$CURRENT_STEP exit_code=$exit_code" >&2
  echo "[validate_all] evidence=$EVIDENCE_PATH" >&2
  exit "$exit_code"
}

write_git_dirty_manifest() {
  python3 - "$EVIDENCE_PATH" "$PROFILE" "$ROOT" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

path = Path(sys.argv[1])
profile = sys.argv[2]
root = Path(sys.argv[3])
dirty_paths = subprocess.run(
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
gates = [
    "rust_tests",
    "rust_clippy",
    "python_bytecode_compile",
    "python_daemon_transport_selftest",
    "java_probe",
    "java_dependency_scan",
    "local_lm_smoke",
    "lazarus_stress",
    "platform_contracts",
]
gate_report = {
    gate: {
        "status": "not_run",
        "required": gate in {"rust_tests", "rust_clippy", "python_bytecode_compile", "python_daemon_transport_selftest"},
        "skip_reason": "",
    }
    for gate in gates
}
path.write_text(json.dumps({
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "profile": profile,
    "status": "blocked",
    "blocked_gate": "git_clean_precheck",
    "current_step": "git_clean_precheck",
    "reason": "dirty_worktree",
    "git_clean": False,
    "dirty_paths": dirty_paths,
    "gate_report": gate_report,
    **{gate: "not_run" for gate in gates},
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

trap 'write_failure_on_error "$?"' ERR

CURRENT_STEP="git_clean_precheck"
if [ "${CHECK_GIT_CLEAN:-0}" = "1" ]; then
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "[validate_all] git worktree is not clean; release validation requires a frozen baseline" >&2
    write_git_dirty_manifest
    echo "[validate_all] evidence=$EVIDENCE_PATH" >&2
    git status --short >&2
    exit 3
  fi
fi

CURRENT_STEP="rust_tests"
echo "[validate_all] rust tests"
cargo test --workspace --all-targets
set_gate_result "rust_tests" "passed"

CURRENT_STEP="rust_clippy"
echo "[validate_all] rust clippy"
cargo clippy --workspace --all-targets -- -D warnings
set_gate_result "rust_clippy" "passed"

CURRENT_STEP="python_bytecode_compile"
echo "[validate_all] python bytecode compile"
python3 -m py_compile engine/*.py genesis-daemons/*.py genesis-daemons/*-python/*.py
set_gate_result "python_bytecode_compile" "passed"

CURRENT_STEP="python_daemon_transport_selftest"
echo "[validate_all] Python daemon transport selftest"
python3 genesis-daemons/daemon_transport.py --selftest
GENESIS_WEB_ARENA_PORT=bad \
GENESIS_WEB_STATE_TIMEOUT_MS=bad \
GENESIS_WEB_ACTION_TIMEOUT_MS=bad \
GENESIS_WEB_REFRESH_SEC=bad \
GENESIS_WEB_ACTION_QUEUE=bad \
GENESIS_DYNAMIC_ARENA_PORT=bad \
GENESIS_DYNAMIC_ACTION_QUEUE=bad \
GENESIS_DYNAMIC_FPS=bad \
GENESIS_DYNAMIC_WIDTH=bad \
GENESIS_DYNAMIC_HEIGHT=bad \
GENESIS_DYNAMIC_FRESH_FRAME_TOLERANCE=bad \
GENESIS_DYNAMIC_MAX_DRIFT_PX=bad \
GENESIS_N_CTX=bad \
GENESIS_N_GPU_LAYERS=bad \
GENESIS_N_THREADS=bad \
GENESIS_LLM_LATENCY_SEC=bad \
python3 - <<'PY'
import importlib
import sys
import tempfile
import types
from pathlib import Path

root = Path("genesis-daemons").resolve()
for extra in [
    root,
    root / "web-arena-python",
    root / "dynamic-arena-python",
    root / "llm-daemon-python",
]:
    sys.path.insert(0, str(extra))

for name in ["web_arena", "arena_engine", "uds_server", "llm_daemon"]:
    importlib.import_module(name)

model_path = Path(tempfile.gettempdir()) / "genesis-invalid-env-selftest.gguf"
model_path.touch()
fake_llama_cpp = types.ModuleType("llama_cpp")

class FakeLlama:
    def __init__(self, **kwargs):
        self.kwargs = kwargs

fake_llama_cpp.Llama = FakeLlama
sys.modules["llama_cpp"] = fake_llama_cpp
llm_daemon = sys.modules["llm_daemon"]
llm_daemon.os.environ["GENESIS_MODEL_PATH"] = str(model_path)
model = llm_daemon.load_model()
assert isinstance(model, FakeLlama)
assert model.kwargs["n_ctx"] == 4096
assert model.kwargs["n_gpu_layers"] == -1
assert model.kwargs["n_threads"] == 8
PY
set_gate_result "python_daemon_transport_selftest" "passed"

CURRENT_STEP="java_probe"
if [ "${RUN_JAVA_PROBE:-1}" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[validate_all] docker is required for Java probe validation; set RUN_JAVA_PROBE=0 to skip" >&2
    fail_current_step 1 "docker_missing"
  fi
  echo "[validate_all] java probe package and corpus validation"
  bash "$ROOT/scripts/validate_lazarus_java_probe.sh"
  set_gate_result "java_probe" "passed"
else
  echo "[validate_all] skipping Java probe validation"
  set_gate_result "java_probe" "skipped"
fi

CURRENT_STEP="java_dependency_scan"
if [ "${RUN_JAVA_DEPENDENCY_SCAN:-0}" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[validate_all] docker is required for Java dependency scan" >&2
    fail_current_step 1 "docker_missing"
  fi
  echo "[validate_all] java dependency CVE scan"
  bash "$ROOT/scripts/validate_lazarus_java_dependency_scan.sh"
  set_gate_result "java_dependency_scan" "passed"
else
  echo "[validate_all] skipping Java dependency CVE scan"
  set_gate_result "java_dependency_scan" "skipped"
fi

CURRENT_STEP="local_lm_smoke"
if [ "${RUN_LOCAL_LM_SMOKE:-0}" = "1" ]; then
  echo "[validate_all] local LM synthesis smoke"
  bash "$ROOT/scripts/run_lazarus_local_lm_synthesis_smoke.sh"
  set_gate_result "local_lm_smoke" "passed"
else
  echo "[validate_all] skipping local LM synthesis smoke"
  set_gate_result "local_lm_smoke" "skipped"
fi

CURRENT_STEP="lazarus_stress"
if [ "${RUN_LAZARUS_STRESS:-0}" = "1" ]; then
  echo "[validate_all] Lazarus lifecycle stress"
  bash "$ROOT/scripts/validate_lazarus_stress.sh"
  set_gate_result "lazarus_stress" "passed"
else
  echo "[validate_all] skipping Lazarus lifecycle stress"
  set_gate_result "lazarus_stress" "skipped"
fi

CURRENT_STEP="platform_contracts"
if [ "${RUN_PLATFORM_CONTRACTS:-0}" = "1" ] && [ "${GENESIS_PLATFORM_CONTRACTS_PRECHECKED:-0}" = "1" ]; then
  echo "[validate_all] platform contract checks already passed in this run"
  set_gate_result "platform_contracts" "passed"
elif [ "${RUN_PLATFORM_CONTRACTS:-0}" = "1" ]; then
  echo "[validate_all] platform contract checks"
  GENESIS_PLATFORM_CONTRACT_EVIDENCE="${GENESIS_PLATFORM_CONTRACT_EVIDENCE:-${EVIDENCE_PATH%.json}-platform-contracts.json}" \
    bash "$ROOT/scripts/validate_platform_contracts.sh"
  set_gate_result "platform_contracts" "passed"
else
  echo "[validate_all] skipping platform contract checks"
  set_gate_result "platform_contracts" "skipped"
fi

CURRENT_STEP="success_manifest"
write_success_manifest
echo "[validate_all] ok"
echo "[validate_all] evidence=$EVIDENCE_PATH"

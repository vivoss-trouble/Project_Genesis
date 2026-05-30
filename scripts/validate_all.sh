#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${GENESIS_VALIDATE_PROFILE:-default}"
EVIDENCE_PATH="${GENESIS_VALIDATE_EVIDENCE:-$ROOT/.genesis-state/validation-evidence-${PROFILE}.json}"

case "$PROFILE" in
  default|pilot|release)
    ;;
  *)
    echo "[validate_all] invalid GENESIS_VALIDATE_PROFILE=$PROFILE; expected default, pilot, or release" >&2
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
  export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-100}"
  export CHECK_GIT_CLEAN="${CHECK_GIT_CLEAN:-1}"
fi

cd "$ROOT"

echo "[validate_all] profile=$PROFILE"

write_success_manifest() {
  mkdir -p "$(dirname "$EVIDENCE_PATH")"
  cat > "$EVIDENCE_PATH" <<JSON
{
  "profile": "$PROFILE",
  "status": "passed",
  "rust_tests": "passed",
  "rust_clippy": "passed",
  "python_bytecode_compile": "passed",
  "java_probe": "$([ "${RUN_JAVA_PROBE:-1}" = "1" ] && echo "passed" || echo "skipped")",
  "java_dependency_scan": "$([ "${RUN_JAVA_DEPENDENCY_SCAN:-0}" = "1" ] && echo "passed" || echo "skipped")",
  "local_lm_smoke": "$([ "${RUN_LOCAL_LM_SMOKE:-0}" = "1" ] && echo "passed" || echo "skipped")",
  "lazarus_stress": "$([ "${RUN_LAZARUS_STRESS:-0}" = "1" ] && echo "passed" || echo "skipped")",
  "skip_reasons": {
    "java_probe": "$([ "${RUN_JAVA_PROBE:-1}" = "1" ] && echo "" || echo "RUN_JAVA_PROBE=0")",
    "java_dependency_scan": "$([ "${RUN_JAVA_DEPENDENCY_SCAN:-0}" = "1" ] && echo "" || echo "RUN_JAVA_DEPENDENCY_SCAN=0")",
    "local_lm_smoke": "$([ "${RUN_LOCAL_LM_SMOKE:-0}" = "1" ] && echo "" || echo "RUN_LOCAL_LM_SMOKE=0")",
    "lazarus_stress": "$([ "${RUN_LAZARUS_STRESS:-0}" = "1" ] && echo "" || echo "RUN_LAZARUS_STRESS=0")"
  }
}
JSON
}

if [ "${CHECK_GIT_CLEAN:-0}" = "1" ]; then
  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "[validate_all] git worktree is not clean; release validation requires a frozen baseline" >&2
    git status --short >&2
    exit 3
  fi
fi

echo "[validate_all] rust tests"
cargo test --workspace --all-targets

echo "[validate_all] rust clippy"
cargo clippy --workspace --all-targets -- -D warnings

echo "[validate_all] python bytecode compile"
python3 -m py_compile engine/*.py genesis-daemons/*.py genesis-daemons/*-python/*.py

if [ "${RUN_JAVA_PROBE:-1}" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[validate_all] docker is required for Java probe validation; set RUN_JAVA_PROBE=0 to skip" >&2
    exit 1
  fi
  echo "[validate_all] java probe package and corpus validation"
  bash "$ROOT/scripts/validate_lazarus_java_probe.sh"
else
  echo "[validate_all] skipping Java probe validation"
fi

if [ "${RUN_JAVA_DEPENDENCY_SCAN:-0}" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "[validate_all] docker is required for Java dependency scan" >&2
    exit 1
  fi
  echo "[validate_all] java dependency CVE scan"
  bash "$ROOT/scripts/validate_lazarus_java_dependency_scan.sh"
else
  echo "[validate_all] skipping Java dependency CVE scan"
fi

if [ "${RUN_LOCAL_LM_SMOKE:-0}" = "1" ]; then
  echo "[validate_all] local LM synthesis smoke"
  bash "$ROOT/scripts/run_lazarus_local_lm_synthesis_smoke.sh"
else
  echo "[validate_all] skipping local LM synthesis smoke"
fi

if [ "${RUN_LAZARUS_STRESS:-0}" = "1" ]; then
  echo "[validate_all] Lazarus lifecycle stress"
  bash "$ROOT/scripts/validate_lazarus_stress.sh"
else
  echo "[validate_all] skipping Lazarus lifecycle stress"
fi

write_success_manifest
echo "[validate_all] ok"
echo "[validate_all] evidence=$EVIDENCE_PATH"

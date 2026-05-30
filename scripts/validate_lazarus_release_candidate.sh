#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export GENESIS_VALIDATE_PROFILE=release
export RUN_JAVA_PROBE="${RUN_JAVA_PROBE:-1}"
export RUN_JAVA_DEPENDENCY_SCAN="${RUN_JAVA_DEPENDENCY_SCAN:-1}"
export RUN_LOCAL_LM_SMOKE="${RUN_LOCAL_LM_SMOKE:-1}"
export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-100}"
export CHECK_GIT_CLEAN="${CHECK_GIT_CLEAN:-1}"

bash "$ROOT/scripts/validate_all.sh"

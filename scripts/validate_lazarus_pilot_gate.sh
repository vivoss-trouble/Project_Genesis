#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export GENESIS_VALIDATE_PROFILE=pilot
export RUN_JAVA_PROBE="${RUN_JAVA_PROBE:-1}"
export RUN_LAZARUS_STRESS="${RUN_LAZARUS_STRESS:-1}"
export LAZARUS_STRESS_ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-20}"

bash "$ROOT/scripts/validate_all.sh"

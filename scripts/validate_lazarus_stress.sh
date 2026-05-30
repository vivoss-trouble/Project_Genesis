#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERATIONS="${LAZARUS_STRESS_ITERATIONS:-20}"

cd "$ROOT"

run_exact_test() {
  local package="$1"
  local test_name="$2"
  cargo test -p "$package" "$test_name" -- --exact
}

for i in $(seq 1 "$ITERATIONS"); do
  echo "[lazarus_stress] iteration $i/$ITERATIONS"
  run_exact_test genesis-core act::tests::verifier_retains_actions_until_delivery_reaches_terminal_state
  run_exact_test genesis-core audit::tests::rotates_audit_file_at_configured_size_limit
  run_exact_test lazarus-artifact-runner tests::kills_and_reaps_timed_out_artifact
  run_exact_test lazarus-artifact-runner tests::native_artifact_public_api_requires_explicit_dev_mode
  run_exact_test lazarus-shadow-runner tests::async_queue_drops_when_capacity_is_full_without_blocking
  run_exact_test lazarus-shadow-runner tests::async_worker_retires_after_lifecycle_limit
  run_exact_test lazarus-shadow-runner tests::supervised_queue_respawns_retired_workers
  run_exact_test lazarus-shadow-runner tests::supervised_queue_runs_worker_pool_with_single_ledger_writer
  run_exact_test lazarus-shadow-runner tests::tokio_shadow_pool_uses_spawn_blocking_and_single_writer
done

echo "[lazarus_stress] ok"

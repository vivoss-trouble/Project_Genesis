#!/usr/bin/env bash
set -euo pipefail

count="${1:-100000}"
batch_size="${2:-1000}"
if [[ "${3:-}" != "" ]]; then
  db_path="$3"
else
  tmp_dir="$(mktemp -d /tmp/lazarus-sqlite-ledger-bench.XXXXXX)"
  db_path="$tmp_dir/bench.sqlite"
fi

cargo run -p lazarus-orchestrator-store --bin bench_sqlite_ledger -- \
  "$count" "$batch_size" "$db_path"

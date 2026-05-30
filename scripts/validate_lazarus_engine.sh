#!/usr/bin/env bash
set -euo pipefail

bash scripts/validate_lazarus_java_probe.sh
cargo test -p lazarus-contracts -p lazarus-orchestrator -p lazarus-scanner -p lazarus-ir-extractor -p lazarus-verifier-bridge -p lazarus-verifier-runner -p lazarus-verification-pipeline -p lazarus-converter-pipeline -p lazarus-cutover-gate -p lazarus-shadow-runner -p lazarus-promotion-controller -p lazarus-e2e -p lazarus-evidence-pack -p lazarus-breakwater -p lazarus-artifact-runner -p lazarus-synthesizer -p lazarus-orchestrator-store -p genesis-cli
tmp_crate="$(mktemp -d /tmp/lazarus-cli-smoke.XXXXXX)"
mkdir -p "$tmp_crate/src"
printf '[package]\nname = "cli_smoke"\nversion = "0.1.0"\nedition = "2024"\n' > "$tmp_crate/Cargo.toml"
printf 'pub fn legacy_fee(amount: i64) -> i64 { amount * 2 }\npub fn refactored_fee(amount: i64) -> i64 { amount + amount }\n' > "$tmp_crate/src/lib.rs"
cargo run -p genesis-cli -- lazarus-smoke "$tmp_crate" legacy_fee refactored_fee "$tmp_crate/out"
python3 engine/ShadowAgent.py
python3 engine/VerificationKernel.py
rustc --test engine/CodeConverter.rs -o /tmp/lazarus_code_converter_test
/tmp/lazarus_code_converter_test
rustfmt --check engine/CodeConverter.rs

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_PATH="${GENESIS_V64_PROBE_BIN:-/tmp/genesis_v64_calculator_frame_stability_probe}"

open -a Calculator || true
sleep "${GENESIS_V64_CALCULATOR_SETTLE_SEC:-1.0}"

swiftc scripts/probe_v64_calculator_frame_stability.swift -o "$BIN_PATH"
"$BIN_PATH"

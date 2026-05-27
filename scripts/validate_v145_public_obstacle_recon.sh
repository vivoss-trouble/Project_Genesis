#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOG_PATH="${GENESIS_VALIDATE_V145_LOG:-/tmp/genesis_validate_v145_public_obstacle_recon.log}"

echo "========================================================================"
echo "Genesis v14.5a Public Obstacle Recon Validation"
echo "========================================================================"

./scripts/run_v145_public_obstacle_recon.sh | tee "$LOG_PATH"

python3 - "$LOG_PATH" <<'PY'
import json
import sys

events = []
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw in handle:
        raw = raw.strip()
        if raw.startswith("{"):
            events.append(json.loads(raw))

summary = next((event for event in events if event.get("event") == "v145_public_obstacle_recon_summary"), None)
if summary is None:
    raise SystemExit("[v14.5a] missing public obstacle recon summary")
samples = [event for event in events if event.get("event") == "v145_public_obstacle_recon_sample"]
if not any(sample.get("status") == "ok" for sample in samples):
    raise SystemExit(f"[v14.5a] public recon never reached a probe-ready window: {samples}")

for payload in events:
    if payload.get("posted") is not False:
        raise SystemExit(f"[v14.5a] read-only recon must not post: {payload}")
    if payload.get("physical_input_posted") not in (None, False):
        raise SystemExit(f"[v14.5a] read-only recon leaked physical input: {payload}")

if summary.get("safe_to_arm") is True:
    if summary.get("public_obstacle_seen") is not True:
        raise SystemExit(f"[v14.5a] safe_to_arm without obstacle: {summary}")
    if summary.get("occluder_kind") != "modal":
        raise SystemExit(f"[v14.5a] safe_to_arm requires modal occluder: {summary}")
    if summary.get("legal_candidate_count") != 1:
        raise SystemExit(f"[v14.5a] safe_to_arm requires exactly one legal candidate: {summary}")
    if summary.get("rejected_candidate_count", 0) < 1:
        raise SystemExit(f"[v14.5a] safe_to_arm requires at least one rejected decoy: {summary}")

print(json.dumps({
    "event": "v145_public_obstacle_recon_assertions",
    "target_url": summary.get("target_url"),
    "public_obstacle_seen": summary.get("public_obstacle_seen"),
    "occluder_kind": summary.get("occluder_kind"),
    "candidate_count": summary.get("candidate_count"),
    "legal_candidate_count": summary.get("legal_candidate_count"),
    "safe_to_arm": summary.get("safe_to_arm"),
    "posted": False,
}, sort_keys=True))
PY

echo "========================================================================"
echo "Genesis v14.5a public obstacle recon validation passed"
echo "========================================================================"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IN_DIR="${GENESIS_PREFLIGHT_OUT_DIR:-$ROOT/.genesis-state/preflight-external-evidence}"
SUMMARY_PATH="${GENESIS_PREFLIGHT_SUMMARY:-$IN_DIR/summary.json}"
REQUIRE_ALL="${GENESIS_REQUIRE_PREFLIGHT_EXTERNAL_EVIDENCE:-0}"

cd "$ROOT"

python3 - "$IN_DIR" "$SUMMARY_PATH" "$REQUIRE_ALL" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
import json
import subprocess
import sys

in_dir = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
require_all = sys.argv[3] == "1"

required = [
    "desktop_macos",
    "desktop_linux",
    "desktop_windows",
    "ios_simulator",
    "android_emulator",
    "self_signed_artifact",
]

git_head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() or "unknown"
dirty_paths = subprocess.run(["git", "status", "--short"], capture_output=True, text=True).stdout.splitlines()

entries = {}
missing = []
invalid = []
passed = []

for kind in required:
    path = in_dir / f"{kind}.json"
    entry = {"path": str(path), "exists": path.exists()}
    if not path.exists():
        missing.append(kind)
        entries[kind] = entry
        continue
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        entry["json_error"] = str(error)
        invalid.append(kind)
        entries[kind] = entry
        continue

    entry.update({
        "status": data.get("status"),
        "git_head": data.get("git_head"),
        "git_dirty": data.get("git_dirty"),
        "preflight_evidence": data.get("preflight_evidence"),
        "not_release_evidence": data.get("not_release_evidence"),
        "real_host_smoke": data.get("real_host_smoke"),
        "real_signing_evidence": data.get("real_signing_evidence"),
    })
    if data.get("status") != "passed":
        entry["reason"] = "status_not_passed"
        invalid.append(kind)
    elif data.get("git_head") != git_head:
        entry["reason"] = "git_head_mismatch"
        invalid.append(kind)
    elif data.get("git_dirty") is not False:
        entry["reason"] = "dirty_evidence"
        invalid.append(kind)
    elif data.get("preflight_evidence") is not True:
        entry["reason"] = "not_preflight_evidence"
        invalid.append(kind)
    elif data.get("not_release_evidence") is not True:
        entry["reason"] = "release_boundary_missing"
        invalid.append(kind)
    elif data.get("real_host_smoke") is not False:
        entry["reason"] = "preflight_claims_real_host_smoke"
        invalid.append(kind)
    elif data.get("real_signing_evidence") is not False:
        entry["reason"] = "preflight_claims_real_signing"
        invalid.append(kind)
    else:
        passed.append(kind)
    entries[kind] = entry

status = "passed" if not missing and not invalid else "partial"
reason = ""
if invalid:
    reason = "invalid_preflight_evidence:" + ",".join(invalid)
elif missing:
    reason = "missing_preflight_evidence:" + ",".join(missing)

summary = {
    "schema_version": 1,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "git_head": git_head,
    "git_dirty": bool(dirty_paths),
    "status": status,
    "reason": reason,
    "claim": "preflight_only_not_release_evidence",
    "required_kinds": required,
    "passed_kinds": passed,
    "missing_kinds": missing,
    "invalid_kinds": invalid,
    "entries": entries,
}

summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"[preflight_evidence] status={status} evidence={summary_path}")

if require_all and status != "passed":
    raise SystemExit(1)
PY

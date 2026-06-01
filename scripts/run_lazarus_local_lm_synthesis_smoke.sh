#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$ROOT/config/reasoning-engine.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/config/reasoning-engine.env"
  set +a
fi

ENDPOINT="${LAZARUS_LM_ENDPOINT:-http://127.0.0.1:1234/v1/chat/completions}"
MODELS_ENDPOINT="${ENDPOINT%/chat/completions}/models"
SNAPSHOT_DIR="${LAZARUS_LM_SNAPSHOT_DIR:-$ROOT/lazarus-java-probe/target/probe-it-snapshots}"
OUT_DIR="${LAZARUS_LM_OUT_DIR:-$(mktemp -d /tmp/lazarus-local-lm-synth.XXXXXX)}"
REPORT_DIR="${LAZARUS_LM_REPORT_DIR:-$OUT_DIR/corpus-report}"
MODELS_JSON="$OUT_DIR/models.json"
JAVA_SOURCE="$OUT_DIR/LocalLmPilotSource.java"

mkdir -p "$OUT_DIR" "$REPORT_DIR"

if ! curl -fsS --max-time 2 "$MODELS_ENDPOINT" >"$MODELS_JSON"; then
  echo "local LM endpoint is not reachable: $MODELS_ENDPOINT" >&2
  echo "start LM Studio local server or set LAZARUS_LM_ENDPOINT" >&2
  exit 1
fi

MODEL="${LAZARUS_LM_MODEL:-$(python3 - "$MODELS_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
models = [item["id"] for item in data.get("data", []) if "embedding" not in item.get("id", "").lower()]
if not models:
    raise SystemExit("no non-embedding local LM models found")
print(models[0])
PY
)}"

if [ ! -d "$SNAPSHOT_DIR" ] || ! find "$SNAPSHOT_DIR" -name '*.jsonl' -size +0 -print -quit | grep -q .; then
  echo "probe snapshots not found; generating dummy Java probe snapshots first" >&2
  bash "$ROOT/scripts/validate_lazarus_java_probe.sh" >"$OUT_DIR/probe-validate.log"
fi

cargo build -p genesis-cli >"$OUT_DIR/cargo-build.log"
"$ROOT/target/debug/genesis-cli" corpus-report "$SNAPSHOT_DIR" "$REPORT_DIR/corpus-report.json" >"$OUT_DIR/corpus-report.log"

BUSINESS_METHOD="${LAZARUS_LM_BUSINESS_METHOD:-$(python3 - "$REPORT_DIR/corpus-report.json" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    report = json.load(fh)
candidates = report.get("pilot_candidates", [])
if not candidates:
    raise SystemExit("no pilot candidates found")
print(candidates[0]["business_method"])
PY
)}"

cat > "$JAVA_SOURCE" <<'JAVA'
public final class LocalLmPilotSource {
    public long compute(long id) {
        // The pilot endpoint returns the number of account rows matching the request id.
        if (id == 1L) {
            return 1L;
        }
        if (id == 999L) {
            return 2L;
        }
        return 0L;
    }
}
JAVA

export LAZARUS_ORACLE_PROTOCOL="${LAZARUS_ORACLE_PROTOCOL:-openai_chat}"
export LAZARUS_LM_ENDPOINT="$ENDPOINT"
export LAZARUS_LM_MODEL="$MODEL"
export LAZARUS_ORACLE_MAX_RETRIES="${LAZARUS_ORACLE_MAX_RETRIES:-1}"
export LAZARUS_ORACLE_TIMEOUT_MS="${LAZARUS_ORACLE_TIMEOUT_MS:-120000}"
export LAZARUS_ORACLE_MAX_OUTPUT_TOKENS="${LAZARUS_ORACLE_MAX_OUTPUT_TOKENS:-4096}"
export LAZARUS_ORACLE_LOG_DIR="${LAZARUS_ORACLE_LOG_DIR:-$OUT_DIR/oracle-logs}"

"$ROOT/target/debug/genesis-cli" synthesis-smoke "$SNAPSHOT_DIR" "$BUSINESS_METHOD" "$JAVA_SOURCE" "$OUT_DIR"

python3 - "$OUT_DIR" "$ENDPOINT" "$MODEL" "$BUSINESS_METHOD" "$SNAPSHOT_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])
endpoint = sys.argv[2]
model = sys.argv[3]
business_method = sys.argv[4]
snapshot_dir = pathlib.Path(sys.argv[5])

def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

artifacts = []
for path in sorted(out_dir.rglob("*")):
    if path.is_file() and path.name != "local-lm-smoke-manifest.json":
        artifacts.append({
            "path": str(path.relative_to(out_dir)),
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        })

manifest = {
    "schema_version": 1,
    "event": "lazarus_local_lm_synthesis_smoke",
    "status": "passed",
    "endpoint": endpoint,
    "model": model,
    "business_method": business_method,
    "snapshot_dir": str(snapshot_dir),
    "artifacts": artifacts,
}
(out_dir / "local-lm-smoke-manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "local LM synthesis smoke:"
echo "  endpoint=$ENDPOINT"
echo "  model=$MODEL"
echo "  business_method=$BUSINESS_METHOD"
echo "  out_dir=$OUT_DIR"
echo "  report=$OUT_DIR/synthesis-smoke-report.json"
echo "  manifest=$OUT_DIR/local-lm-smoke-manifest.json"

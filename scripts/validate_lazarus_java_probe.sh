#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="$ROOT/lazarus-java-probe"
INGEST_OUT="$(mktemp -d /tmp/lazarus-java-probe-ingest.XXXXXX)"
REPORT_OUT="$(mktemp -d /tmp/lazarus-java-probe-report.XXXXXX)"
MAVEN_CACHE="$ROOT/.cache/lazarus-m2"
MAVEN_IMAGE="${LAZARUS_JAVA_PROBE_MAVEN_IMAGE:-maven:3.9-eclipse-temurin-17}"

command -v docker >/dev/null 2>&1
mkdir -p "$MAVEN_CACHE"

docker run --rm \
  -v "$PROBE_DIR:/app" \
  -v "$MAVEN_CACHE:/root/.m2" \
  -w /app \
  "$MAVEN_IMAGE" \
  mvn clean package

test -f "$PROBE_DIR/target/lazarus-java-probe-0.1.0-all.jar"
test -d "$PROBE_DIR/target/probe-it-snapshots"

docker run --rm \
  -v "$PROBE_DIR:/app" \
  -v "$MAVEN_CACHE:/root/.m2" \
  -w /app \
  "$MAVEN_IMAGE" \
  sh -c 'jar tf target/lazarus-java-probe-0.1.0-all.jar > target/shaded-jar-contents.txt && grep -q "com/genesis/lazarus/shadow/jackson" target/shaded-jar-contents.txt && ! grep -q "com/fasterxml/jackson/databind/ObjectMapper.class" target/shaded-jar-contents.txt'

cargo build -p genesis-cli
"$ROOT/target/debug/genesis-cli" corpus-ingest "$PROBE_DIR/target/probe-it-snapshots" "$INGEST_OUT"
"$ROOT/target/debug/genesis-cli" corpus-report "$PROBE_DIR/target/probe-it-snapshots" "$REPORT_OUT/corpus-report.json"
python3 - "$INGEST_OUT/corpus-ingest-manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
if manifest["accepted_count"] < 3:
    raise SystemExit(f"expected at least three accepted Java probe snapshots: {manifest}")
if manifest["rejected_count"] != 0:
    raise SystemExit(f"expected zero rejected Java probe snapshots: {manifest}")
PY
python3 - "$REPORT_OUT/corpus-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    report = json.load(fh)
if report["total_snapshots"] < 3:
    raise SystemExit(f"expected at least three reported snapshots: {report}")
if report["valid_ingestable_count"] < 3:
    raise SystemExit(f"expected at least three valid reported snapshots: {report}")
if report["missing_trace_tag_count"] != 0:
    raise SystemExit(f"expected Java probe snapshots to include business_method trace tags: {report}")
if report["method_count"] < 1:
    raise SystemExit(f"expected at least one business method bucket: {report}")
PY

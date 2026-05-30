#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="$ROOT/lazarus-java-probe"
MAVEN_CACHE="$ROOT/.cache/lazarus-m2"
DEPENDENCY_CHECK_DATA="$ROOT/.cache/dependency-check-data"
MAVEN_IMAGE="${LAZARUS_JAVA_PROBE_MAVEN_IMAGE:-maven:3.9-eclipse-temurin-17}"
DEPENDENCY_CHECK_VERSION="${OWASP_DEPENDENCY_CHECK_VERSION:-12.2.2}"
FAIL_ON_CVSS="${OWASP_DEPENDENCY_CHECK_FAIL_ON_CVSS:-7}"

command -v docker >/dev/null 2>&1
mkdir -p "$MAVEN_CACHE" "$DEPENDENCY_CHECK_DATA"

if [ -z "${NVD_API_KEY:-}" ] && [ "${ALLOW_UNKEYED_NVD:-0}" != "1" ]; then
  echo "[java_dependency_scan] NVD_API_KEY is required; set ALLOW_UNKEYED_NVD=1 only for local exploratory scans" >&2
  exit 2
fi

NVD_ARGS=()
if [ -n "${NVD_API_KEY:-}" ]; then
  NVD_ARGS+=("-DnvdApiKey=${NVD_API_KEY}")
fi

docker run --rm \
  -v "$PROBE_DIR:/app" \
  -v "$MAVEN_CACHE:/root/.m2" \
  -v "$DEPENDENCY_CHECK_DATA:/dependency-check-data" \
  -w /app \
  "$MAVEN_IMAGE" \
  mvn -B "org.owasp:dependency-check-maven:${DEPENDENCY_CHECK_VERSION}:check" \
    "-DdataDirectory=/dependency-check-data" \
    "-DfailBuildOnCVSS=${FAIL_ON_CVSS}" \
    "-Dformat=JSON" \
    "-DretireJsAnalyzerEnabled=false" \
    "${NVD_ARGS[@]}"

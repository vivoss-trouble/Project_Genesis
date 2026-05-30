#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${NVD_CVE_ENDPOINT:-https://services.nvd.nist.gov/rest/json/cves/2.0}"
CVE_ID="${NVD_PROBE_CVE_ID:-CVE-2021-44228}"
TIMEOUT_SECONDS="${NVD_PROBE_TIMEOUT_SECONDS:-20}"
OUT_FILE="$(mktemp /tmp/lazarus-nvd-connectivity.XXXXXX.json)"
trap 'rm -f "$OUT_FILE"' EXIT

if [ -z "${NVD_API_KEY:-}" ] && [ "${ALLOW_UNKEYED_NVD:-0}" != "1" ]; then
  echo "[nvd_connectivity] NVD_API_KEY is required; set ALLOW_UNKEYED_NVD=1 only for local exploratory checks" >&2
  exit 2
fi

CURL_ARGS=(
  -fsS
  --max-time "$TIMEOUT_SECONDS"
  --get "$ENDPOINT"
  --data-urlencode "cveId=$CVE_ID"
  -o "$OUT_FILE"
  -w "%{http_code}"
)

if [ -n "${NVD_API_KEY:-}" ]; then
  CURL_ARGS+=(-H "apiKey: ${NVD_API_KEY}")
fi

set +e
HTTP_CODE="$(curl "${CURL_ARGS[@]}")"
CURL_STATUS=$?
set -e

if [ "$HTTP_CODE" = "429" ]; then
  echo "[nvd_connectivity] rate limited by NVD API (HTTP 429)" >&2
  exit 3
fi

if [ "$CURL_STATUS" -ne 0 ]; then
  echo "[nvd_connectivity] curl failed with status $CURL_STATUS, http=$HTTP_CODE" >&2
  exit "$CURL_STATUS"
fi

if [ "$HTTP_CODE" != "200" ]; then
  echo "[nvd_connectivity] unexpected HTTP status: $HTTP_CODE" >&2
  exit 4
fi

python3 - "$OUT_FILE" "$CVE_ID" <<'PY'
import json
import sys

path, expected_cve = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

items = payload.get("vulnerabilities", [])
if not items:
    raise SystemExit(f"[nvd_connectivity] no vulnerabilities returned for {expected_cve}")

seen = {
    item.get("cve", {}).get("id")
    for item in items
    if isinstance(item, dict)
}
if expected_cve not in seen:
    raise SystemExit(f"[nvd_connectivity] expected {expected_cve}, got {sorted(seen)}")

print(f"[nvd_connectivity] ok cve={expected_cve} results={len(items)}")
PY

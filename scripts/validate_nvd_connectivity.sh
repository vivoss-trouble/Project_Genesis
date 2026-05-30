#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${NVD_CVE_ENDPOINT:-https://services.nvd.nist.gov/rest/json/cves/2.0}"
CVE_ID="${NVD_PROBE_CVE_ID:-CVE-2021-44228}"
TIMEOUT_SECONDS="${NVD_PROBE_TIMEOUT_SECONDS:-20}"
MAX_RETRIES="${NVD_PROBE_MAX_RETRIES:-5}"
BASE_BACKOFF_SECONDS="${NVD_PROBE_BASE_BACKOFF_SECONDS:-6}"
MAX_BACKOFF_SECONDS="${NVD_PROBE_MAX_BACKOFF_SECONDS:-60}"
OUT_FILE="$(mktemp /tmp/lazarus-nvd-connectivity.XXXXXX.json)"
HEADER_FILE="$(mktemp /tmp/lazarus-nvd-connectivity.XXXXXX.headers)"
trap 'rm -f "$OUT_FILE" "$HEADER_FILE"' EXIT

if [ -z "${NVD_API_KEY:-}" ] && [ "${ALLOW_UNKEYED_NVD:-0}" != "1" ]; then
  echo "[nvd_connectivity] NVD_API_KEY is required; set ALLOW_UNKEYED_NVD=1 only for local exploratory checks" >&2
  exit 2
fi

retry_after_seconds() {
  awk 'BEGIN { IGNORECASE = 1 }
    /^retry-after:/ {
      gsub("\r", "", $2);
      if ($2 ~ /^[0-9]+$/) {
        print $2;
        exit;
      }
    }' "$HEADER_FILE"
}

backoff_seconds() {
  local attempt="$1"
  local retry_after
  retry_after="$(retry_after_seconds)"
  if [ -n "$retry_after" ]; then
    printf '%s\n' "$retry_after"
    return
  fi
  local exp=$((BASE_BACKOFF_SECONDS * (2 ** (attempt - 1))))
  if [ "$exp" -gt "$MAX_BACKOFF_SECONDS" ]; then
    exp="$MAX_BACKOFF_SECONDS"
  fi
  local jitter=0
  if [ "$exp" -gt 1 ]; then
    jitter=$((RANDOM % exp))
  fi
  printf '%s\n' $((exp + jitter))
}

print_rate_headers() {
  awk 'BEGIN { IGNORECASE = 1 }
    /^retry-after:/ || /^x-ratelimit/ || /^ratelimit/ {
      gsub("\r", "");
      print "  " $0;
    }' "$HEADER_FILE"
}

HTTP_CODE=""
CURL_STATUS=0
for attempt in $(seq 1 "$MAX_RETRIES"); do
  : >"$OUT_FILE"
  : >"$HEADER_FILE"
  CURL_ARGS=(
    -sS
    --max-time "$TIMEOUT_SECONDS"
    --get "$ENDPOINT"
    --data-urlencode "cveId=$CVE_ID"
    -D "$HEADER_FILE"
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

  if [ "$CURL_STATUS" -ne 0 ]; then
    echo "[nvd_connectivity] curl failed attempt=$attempt/$MAX_RETRIES status=$CURL_STATUS http=$HTTP_CODE" >&2
  elif [ "$HTTP_CODE" = "429" ]; then
    echo "[nvd_connectivity] rate limited attempt=$attempt/$MAX_RETRIES (HTTP 429)" >&2
    print_rate_headers >&2
  elif [ "$HTTP_CODE" = "200" ]; then
    break
  else
    echo "[nvd_connectivity] unexpected HTTP status attempt=$attempt/$MAX_RETRIES: $HTTP_CODE" >&2
  fi

  if [ "$attempt" -ge "$MAX_RETRIES" ]; then
    break
  fi
  sleep_for="$(backoff_seconds "$attempt")"
  echo "[nvd_connectivity] retrying after ${sleep_for}s" >&2
  sleep "$sleep_for"
done

if [ "$CURL_STATUS" -ne 0 ]; then
  exit "$CURL_STATUS"
fi

if [ "$HTTP_CODE" = "429" ]; then
  echo "[nvd_connectivity] exhausted retries after HTTP 429" >&2
  exit 3
fi

if [ "$HTTP_CODE" != "200" ]; then
  echo "[nvd_connectivity] final unexpected HTTP status: $HTTP_CODE" >&2
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

#!/usr/bin/env bash
set -euo pipefail

# Read-only deployment smoke test for the isolated staging service. Keep
# credentials out of command history: export optional values in the current
# shell rather than placing them after this command.
base_url="${WEVAULT_API_BASE_URL:-https://api.wevault.online}"
base_url="${base_url%/}"

fail() {
  printf 'staging acceptance failed: %s\n' "$1" >&2
  exit 1
}

response_headers="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$response_headers" "$response_body"' EXIT

status="$(curl --silent --show-error --fail --output "$response_body" --dump-header "$response_headers" --write-out '%{http_code}' "$base_url/healthz")"
[[ "$status" == "200" ]] || fail "health endpoint returned HTTP $status"
[[ "$(<"$response_body")" == '{"status":"ok"}' ]] || fail "health response is not the expected JSON"
grep -qi '^strict-transport-security:' "$response_headers" || fail "HSTS header is missing"
grep -qi '^x-content-type-options: nosniff' "$response_headers" || fail "X-Content-Type-Options header is missing"

redirect_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' "http://${base_url#https://}/healthz")"
[[ "$redirect_status" == "301" ]] || fail "HTTP does not redirect to HTTPS"

status="$(curl --silent --show-error --output "$response_body" --write-out '%{http_code}' -X POST "$base_url/v1/devices" -H 'content-type: application/json' --data '{}')"
[[ "$status" == "401" ]] || fail "unauthenticated device registration returned HTTP $status"
[[ "$(<"$response_body")" == '{"error":{"code":"AUTH_UNAUTHORIZED","message":"Authentication is required"}}' ]] || fail "unauthenticated error envelope changed"

if [[ -n "${WEVAULT_ACCESS_TOKEN:-}" || -n "${WEVAULT_DEVICE_ID:-}" ]]; then
  [[ -n "${WEVAULT_ACCESS_TOKEN:-}" && -n "${WEVAULT_DEVICE_ID:-}" ]] || fail "set both WEVAULT_ACCESS_TOKEN and WEVAULT_DEVICE_ID for authenticated checks"
  status="$(curl --silent --show-error --output "$response_body" --write-out '%{http_code}' "$base_url/v1/objects?deviceId=${WEVAULT_DEVICE_ID}&sha256=$(printf '0%.0s' {1..64})" -H "authorization: Bearer $WEVAULT_ACCESS_TOKEN")"
  [[ "$status" == "200" ]] || fail "authenticated object fallback query returned HTTP $status"
  grep -q '"objects"' "$response_body" || fail "fallback response has no objects envelope"
fi

printf 'staging acceptance passed: %s\n' "$base_url"

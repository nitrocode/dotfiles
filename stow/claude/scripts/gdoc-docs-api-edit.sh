#!/usr/bin/env bash
# gdoc-docs-api-edit.sh
#
# Apply replace-style edits to a Google Doc via the Docs API's batchUpdate
# replaceAllText. Bypasses Apps Script entirely. Uses gcloud Application
# Default Credentials for auth.
#
# Usage:
#   gdoc-docs-api-edit.sh --doc-id <ID> --edits <FILE.json>
#   gdoc-docs-api-edit.sh --doc-id <ID> --edits-stdin < edits.json
#
# Edits-file shape: same as gdoc-apply-edits.sh. Only edits with type "replace"
# are sent to the Docs API in v1. Other types are listed in stderr as skipped.
#
# Setup (one-time):
#   gcloud auth application-default login \
#     --scopes='openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/documents'
#
# Dependencies: gcloud, jq, curl.
set -euo pipefail

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

DOC_ID=""
EDITS_FILE=""
EDITS_STDIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --doc-id) DOC_ID="$2"; shift 2 ;;
    --edits) EDITS_FILE="$2"; shift 2 ;;
    --edits-stdin) EDITS_STDIN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$DOC_ID" ]] || { echo "error: --doc-id required" >&2; usage; }

if [[ $EDITS_STDIN -eq 1 ]]; then
  EDITS_JSON="$(cat)"
elif [[ -n "$EDITS_FILE" ]]; then
  [[ -f "$EDITS_FILE" ]] || { echo "error: edits file not found: $EDITS_FILE" >&2; exit 2; }
  EDITS_JSON="$(cat "$EDITS_FILE")"
else
  echo "error: --edits FILE or --edits-stdin required" >&2
  usage
fi

if ! printf '%s' "$EDITS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "error: edits JSON must be a top-level array" >&2
  exit 2
fi

# Tool checks. Allow tests to override via env vars.
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
CURL_BIN="${CURL_BIN:-curl}"
for bin in "$GCLOUD_BIN" "$CURL_BIN" jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: required binary not found: $bin" >&2; exit 3;
  }
done

# Surface non-replace edit types so caller knows they were skipped.
SKIPPED="$(printf '%s' "$EDITS_JSON" | jq -c '[.[] | select(.type != "replace") | .type]')"
if [[ "$SKIPPED" != "[]" ]]; then
  echo "warning: skipping non-replace edits (Docs API v1 path only supports replace): $SKIPPED" >&2
fi

# Translate to Docs API batchUpdate requests payload.
REQUESTS_BODY="$(printf '%s' "$EDITS_JSON" \
  | jq -c '{
      requests: [
        .[]
        | select(.type == "replace")
        | {
            replaceAllText: {
              containsText: { text: .find, matchCase: true },
              replaceText: .replace
            }
          }
      ]
    }')"

REQUEST_COUNT="$(printf '%s' "$REQUESTS_BODY" | jq '.requests | length')"
if [[ "$REQUEST_COUNT" == "0" ]]; then
  echo "error: no replace edits to apply" >&2
  exit 2
fi

TOKEN="$("$GCLOUD_BIN" auth application-default print-access-token 2>/dev/null)" || {
  echo "error: failed to get ADC token. Run:" >&2
  echo "  gcloud auth application-default login --scopes='openid,https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/documents'" >&2
  exit 4
}
[[ -n "$TOKEN" ]] || { echo "error: empty ADC token" >&2; exit 4; }

URL="https://docs.googleapis.com/v1/documents/${DOC_ID}:batchUpdate"

HTTP_OUT="$(mktemp)"
HTTP_CODE="$("$CURL_BIN" -sS -o "$HTTP_OUT" -w '%{http_code}' \
  -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$REQUESTS_BODY")"

cat "$HTTP_OUT"
echo
rm -f "$HTTP_OUT"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "error: Docs API returned HTTP $HTTP_CODE" >&2
  exit 5
fi

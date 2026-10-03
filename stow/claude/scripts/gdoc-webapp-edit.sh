#!/usr/bin/env bash
# gdoc-webapp-edit.sh
#
# Apply edits to a Google Doc by POSTing to an Apps Script Web App deployed
# with "Execute as: User accessing the web app" and "Who has access: Anyone
# within <domain>". The script runs as the caller, so it only touches docs the
# caller can access. Caller auth is a standard OAuth access token from gcloud.
#
# Usage:
#   gdoc-webapp-edit.sh --url <URL> --doc-id <ID> --edits <FILE.json>
#   gdoc-webapp-edit.sh --url <URL> --doc-id <ID> --edits-stdin < edits.json
#
# Web App URL is the /exec endpoint from the Apps Script Web App deployment.
# Edits-file shape: same as gdoc-apply-edits.sh. All edit types supported by
# the Apps Script (replace, replaceRegex, insertParagraphAfter,
# insertSectionAfter) work here, since the script does the work server-side.
#
# Dependencies: gcloud (logged in), jq, curl.
set -euo pipefail

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

URL=""
DOC_ID=""
EDITS_FILE=""
EDITS_STDIN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --doc-id) DOC_ID="$2"; shift 2 ;;
    --edits) EDITS_FILE="$2"; shift 2 ;;
    --edits-stdin) EDITS_STDIN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$URL" ]] || { echo "error: --url required" >&2; usage; }
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

GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
CURL_BIN="${CURL_BIN:-curl}"
for bin in "$GCLOUD_BIN" "$CURL_BIN" jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: required binary not found: $bin" >&2; exit 3;
  }
done

PAYLOAD="$(printf '%s' "$EDITS_JSON" \
  | jq -c --arg docId "$DOC_ID" '{docId: $docId, edits: .}')"

TOKEN="$("$GCLOUD_BIN" auth print-access-token 2>/dev/null)" || {
  echo "error: failed to get gcloud access token. Run 'gcloud auth login'." >&2
  exit 4
}
[[ -n "$TOKEN" ]] || { echo "error: empty access token" >&2; exit 4; }

BODY_FILE="$(mktemp)"
HEADERS_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$HEADERS_FILE"' EXIT

HTTP_CODE="$("$CURL_BIN" -sS -L \
  -o "$BODY_FILE" \
  -D "$HEADERS_FILE" \
  -w '%{http_code}' \
  -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "$PAYLOAD")"

CT="$(tr -d '\r' <"$HEADERS_FILE" | grep -i '^content-type:' | tail -1 | tr '[:upper:]' '[:lower:]')"

if [[ "$CT" == *"text/html"* ]]; then
  echo "error: Web App returned HTML (likely auth/consent issue)." >&2
  echo "  Visit the URL in your browser once to grant scopes, then retry:" >&2
  echo "  $URL" >&2
  exit 6
fi

cat "$BODY_FILE"
echo

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "error: Web App returned HTTP $HTTP_CODE" >&2
  exit 5
fi

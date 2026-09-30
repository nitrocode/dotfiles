#!/bin/bash
# Mock `curl` for test-azure-app-add-password.sh. Not a real network client:
# routes by URL prefix to canned responses controlled via env vars.
set -u
printf '%s\n' "$*" >>"$CURL_CALLS_FILE"
for arg in "$@"; do
  case "$arg" in
    https://login.microsoftonline.com/*) printf '%s' "${CURL_MOCK_TOKEN_RESPONSE:-{}}"; exit 0;;
    https://graph.microsoft.com/*) printf '%s' "${CURL_MOCK_ADDPASSWORD_RESPONSE:-{}}"; exit 0;;
  esac
done
echo '{}'

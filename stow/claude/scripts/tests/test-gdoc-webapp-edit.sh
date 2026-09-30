#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/gdoc-webapp-edit.sh.
# Mocks `gcloud` and `curl` via PATH shims.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/gdoc-webapp-edit.sh"
echo "test-gdoc-webapp-edit.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/state"
  export GCLOUD_LOG="$SANDBOX/state/gcloud-calls.txt"
  export CURL_LOG="$SANDBOX/state/curl-calls.txt"
  : >"$GCLOUD_LOG"; : >"$CURL_LOG"

  cat >"$SANDBOX/bin/gcloud" <<'GCLOUD'
#!/bin/bash
echo "args=$*" >>"$GCLOUD_LOG"
if [[ "${GCLOUD_MOCK_EXIT_CODE:-0}" == "0" ]]; then
  printf '%s' "${GCLOUD_MOCK_TOKEN:-mock-access-token}"
fi
exit "${GCLOUD_MOCK_EXIT_CODE:-0}"
GCLOUD
  chmod +x "$SANDBOX/bin/gcloud"

  cat >"$SANDBOX/bin/curl" <<'CURL'
#!/bin/bash
echo "args=$*" >>"$CURL_LOG"
OUT_FILE=""
HEADERS_FILE=""
WRITE_FMT=""
DATA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT_FILE="$2"; shift 2 ;;
    -D) HEADERS_FILE="$2"; shift 2 ;;
    -w) WRITE_FMT="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "body=$DATA" >>"$CURL_LOG"
if [[ -n "$HEADERS_FILE" ]]; then
  CT="${CURL_MOCK_CONTENT_TYPE:-application/json}"
  printf 'HTTP/2 %s\r\nContent-Type: %s\r\n\r\n' "${CURL_MOCK_HTTP_CODE:-200}" "$CT" >"$HEADERS_FILE"
fi
RESP="${CURL_MOCK_BODY:-{\"applied\":9}}"
if [[ -n "$OUT_FILE" ]]; then
  printf '%s' "$RESP" >"$OUT_FILE"
fi
if [[ -n "$WRITE_FMT" ]]; then
  printf '%s' "${CURL_MOCK_HTTP_CODE:-200}"
fi
exit "${CURL_MOCK_EXIT_CODE:-0}"
CURL
  chmod +x "$SANDBOX/bin/curl"

  export GCLOUD_BIN="$SANDBOX/bin/gcloud"
  export CURL_BIN="$SANDBOX/bin/curl"
  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown_sandbox() {
  export PATH="$ORIG_PATH"
  rm -rf "$SANDBOX"
  unset GCLOUD_BIN CURL_BIN GCLOUD_LOG CURL_LOG \
    GCLOUD_MOCK_TOKEN GCLOUD_MOCK_EXIT_CODE \
    CURL_MOCK_BODY CURL_MOCK_HTTP_CODE CURL_MOCK_EXIT_CODE CURL_MOCK_CONTENT_TYPE
}

# 1. Happy path: edits forwarded as {docId, edits}, response surfaced.
test_happy_path() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export CURL_MOCK_BODY='{"applied":1,"skipped":[],"errors":[]}'
  local out rc=0
  out=$("$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc, out=$out"; teardown_sandbox; return 1; }
  assert_contains "$out" '"applied":1' || { teardown_sandbox; return 1; }
  local body
  body=$(grep '^body=' "$CURL_LOG" | head -1 | sed 's/^body=//')
  echo "$body" | jq -e '.docId == "doc-1"' >/dev/null \
    || { echo "    body docId wrong: $body"; teardown_sandbox; return 1; }
  echo "$body" | jq -e '.edits | length == 1' >/dev/null \
    || { echo "    body edits wrong"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 2. HTML response means auth/consent issue.
test_html_response_is_consent_error() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export CURL_MOCK_CONTENT_TYPE='text/html; charset=utf-8'
  export CURL_MOCK_BODY='<html>sign in</html>'
  local out rc=0
  out=$("$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "6" ] || { echo "    expected rc=6, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "auth/consent" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 3. HTTP non-200 surfaces.
test_http_non_200() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export CURL_MOCK_HTTP_CODE=500
  local out rc=0
  out=$("$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "5" ] || { echo "    expected rc=5, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "HTTP 500" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 4. Bearer token forwarded in Authorization header.
test_bearer_token_forwarded() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export GCLOUD_MOCK_TOKEN="ya29.xyz"
  "$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" >/dev/null 2>&1
  assert_contains "$(cat "$CURL_LOG")" "Bearer ya29.xyz" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 5. Missing --url.
test_missing_url() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[]' >"$edits"
  local rc=0
  "$SCRIPT" --doc-id "doc-1" --edits "$edits" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 6. gcloud token failure.
test_token_failure() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export GCLOUD_MOCK_EXIT_CODE=1
  local out rc=0
  out=$("$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "4" ] || { echo "    expected rc=4, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "gcloud auth login" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 7. Stdin edits work.
test_stdin_edits() {
  setup_sandbox
  export CURL_MOCK_BODY='{"applied":1}'
  local out rc=0
  out=$(printf '[{"type":"replace","find":"a","replace":"b"}]' \
    | "$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits-stdin 2>&1) || rc=$?
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" '"applied":1' || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 8. Invalid JSON.
test_invalid_json() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo 'not json' >"$edits"
  local rc=0
  "$SCRIPT" --url "https://script.google.com/x/exec" --doc-id "doc-1" --edits "$edits" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

run_test "happy path" test_happy_path
run_test "HTML response means consent error" test_html_response_is_consent_error
run_test "HTTP non-200 surfaces" test_http_non_200
run_test "bearer token forwarded" test_bearer_token_forwarded
run_test "missing --url" test_missing_url
run_test "gcloud token failure" test_token_failure
run_test "stdin edits work" test_stdin_edits
run_test "invalid JSON" test_invalid_json
print_summary

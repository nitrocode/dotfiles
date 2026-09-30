#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/gdoc-docs-api-edit.sh.
# Mocks `gcloud` and `curl` via PATH shims. No real API calls.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/gdoc-docs-api-edit.sh"
echo "test-gdoc-docs-api-edit.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/state"
  export GCLOUD_LOG="$SANDBOX/state/gcloud-calls.txt"
  export CURL_LOG="$SANDBOX/state/curl-calls.txt"
  : >"$GCLOUD_LOG"
  : >"$CURL_LOG"

  # Mock gcloud. Records call, prints $GCLOUD_MOCK_TOKEN, exits with
  # $GCLOUD_MOCK_EXIT_CODE.
  cat >"$SANDBOX/bin/gcloud" <<'GCLOUD'
#!/bin/bash
echo "args=$*" >>"$GCLOUD_LOG"
if [[ "${GCLOUD_MOCK_EXIT_CODE:-0}" == "0" ]]; then
  printf '%s' "${GCLOUD_MOCK_TOKEN:-mock-token-abc}"
fi
exit "${GCLOUD_MOCK_EXIT_CODE:-0}"
GCLOUD
  chmod +x "$SANDBOX/bin/gcloud"

  # Mock curl. Honors -w '%{http_code}' and -o <file>; records args + body.
  cat >"$SANDBOX/bin/curl" <<'CURL'
#!/bin/bash
echo "args=$*" >>"$CURL_LOG"
OUT_FILE=""
WRITE_FMT=""
NEXT_DATA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT_FILE="$2"; shift 2 ;;
    -w) WRITE_FMT="$2"; shift 2 ;;
    --data) NEXT_DATA="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "body=$NEXT_DATA" >>"$CURL_LOG"
RESP_BODY="${CURL_MOCK_BODY:-{\"replies\":[]}}"
if [[ -n "$OUT_FILE" ]]; then
  printf '%s' "$RESP_BODY" >"$OUT_FILE"
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
    CURL_MOCK_BODY CURL_MOCK_HTTP_CODE CURL_MOCK_EXIT_CODE
}

# 1. Happy path: 9 replace edits get translated to batchUpdate.
test_happy_path() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  cat >"$edits" <<'JSON'
[
  {"type":"replace","find":"3 Flavors","replace":"4 Flavors"},
  {"type":"replace","find":"three","replace":"four"}
]
JSON
  export CURL_MOCK_BODY='{"replies":[{"replaceAllText":{"occurrencesChanged":1}},{"replaceAllText":{"occurrencesChanged":3}}],"writeControl":{"requiredRevisionId":"abc"}}'
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc, out=$out"; teardown_sandbox; return 1; }
  assert_contains "$out" "occurrencesChanged" || { teardown_sandbox; return 1; }
  # Check the request body sent to curl.
  local body
  body=$(grep '^body=' "$CURL_LOG" | head -1 | sed 's/^body=//')
  echo "$body" | jq -e '.requests | length == 2' >/dev/null \
    || { echo "    expected 2 requests, got: $body"; teardown_sandbox; return 1; }
  echo "$body" | jq -e '.requests[0].replaceAllText.containsText.text == "3 Flavors"' >/dev/null \
    || { echo "    first request find wrong"; teardown_sandbox; return 1; }
  echo "$body" | jq -e '.requests[0].replaceAllText.replaceText == "4 Flavors"' >/dev/null \
    || { echo "    first request replace wrong"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 2. Non-replace edits are filtered out and warned about.
test_non_replace_edits_filtered() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  cat >"$edits" <<'JSON'
[
  {"type":"replace","find":"a","replace":"b"},
  {"type":"insertSectionAfter","afterHeading":"X","paragraphs":[]}
]
JSON
  export CURL_MOCK_BODY='{"replies":[{"replaceAllText":{"occurrencesChanged":1}}]}'
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "skipping non-replace edits" || { teardown_sandbox; return 1; }
  local body
  body=$(grep '^body=' "$CURL_LOG" | head -1 | sed 's/^body=//')
  echo "$body" | jq -e '.requests | length == 1' >/dev/null \
    || { echo "    expected 1 request after filter"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 3. No replace edits exits with error.
test_no_replace_edits_errors() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"insertSectionAfter","afterHeading":"X","paragraphs":[]}]' >"$edits"
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "no replace edits to apply" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 4. ADC token fetch failure surfaces remediation.
test_adc_token_failure() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export GCLOUD_MOCK_EXIT_CODE=1
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "4" ] || { echo "    expected rc=4, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "application-default login" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 5. HTTP non-200 from Docs API surfaces.
test_http_non_200() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export CURL_MOCK_HTTP_CODE=403
  export CURL_MOCK_BODY='{"error":{"code":403,"message":"forbidden"}}'
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "5" ] || { echo "    expected rc=5, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "HTTP 403" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 6. Missing --doc-id.
test_missing_doc_id() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[]' >"$edits"
  local rc=0
  "$SCRIPT" --edits "$edits" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 7. Invalid JSON rejected.
test_invalid_json() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo 'not json' >"$edits"
  local out rc=0
  out=$("$SCRIPT" --doc-id "test-doc" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "top-level array" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 8. Authorization header carries the bearer token.
test_authorization_header() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[{"type":"replace","find":"a","replace":"b"}]' >"$edits"
  export GCLOUD_MOCK_TOKEN="ya29.fake-token-xyz"
  "$SCRIPT" --doc-id "test-doc" --edits "$edits" >/dev/null 2>&1
  assert_contains "$(cat "$CURL_LOG")" "Bearer ya29.fake-token-xyz" \
    || { teardown_sandbox; return 1; }
  teardown_sandbox
}

run_test "happy path replace edits" test_happy_path
run_test "non-replace edits filtered + warned" test_non_replace_edits_filtered
run_test "no replace edits errors" test_no_replace_edits_errors
run_test "ADC token failure surfaces remediation" test_adc_token_failure
run_test "HTTP non-200 surfaces" test_http_non_200
run_test "missing --doc-id" test_missing_doc_id
run_test "invalid JSON" test_invalid_json
run_test "Authorization header carries bearer token" test_authorization_header
print_summary

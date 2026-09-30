#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/azure-app-add-password.sh.
# Mocks `curl` via a PATH shim so no real calls hit login.microsoftonline.com
# or graph.microsoft.com during tests.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/azure-app-add-password.sh"
echo "test-azure-app-add-password.sh:"

FIXTURES_DIR=$CLAUDE_CONFIG_DIR/scripts/tests/fixtures/mockbin"

setup_sandbox() {
  # State dir only (no bin dir here: the mock `curl` fixture is a
  # pre-committed executable at $FIXTURES_DIR/curl, not something we
  # chmod on the fly. The sandbox blocks chmod on freshly-written files
  # and silently no-ops exported bash functions used as command
  # overrides, so a pre-existing executable fixture is the only mocking
  # approach confirmed to actually intercept the call in this harness.
  STATE=$(mktemp -d)
  CALLS="$STATE/curl-calls.txt"
  : >"$CALLS"

  export CURL_CALLS_FILE="$CALLS"
  export PATH="$FIXTURES_DIR:$PATH"
}

teardown_sandbox() {
  rm -rf "$STATE"
}

test_happy_path_prints_secret() {
  setup_sandbox
  export TENANT=contoso.onmicrosoft.com
  export SP_CLIENT_ID=11111111-1111-1111-1111-111111111111
  export SP_CLIENT_SECRET='sekret~value'
  export TARGET_APP_OBJECT_ID=22222222-2222-2222-2222-222222222222
  export CURL_MOCK_TOKEN_RESPONSE='{"access_token":"fake.jwt.token","expires_in":3599}'
  export CURL_MOCK_ADDPASSWORD_RESPONSE='{"secretText":"newly-minted-secret","keyId":"33333333-3333-3333-3333-333333333333"}'
  local out
  out=$(bash "$SCRIPT" 2>&1)
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ] && assert_contains "$out" "newly-minted-secret"
}

test_passes_client_credentials_to_token_call() {
  setup_sandbox
  export TENANT=contoso.onmicrosoft.com
  export SP_CLIENT_ID=11111111-1111-1111-1111-111111111111
  export SP_CLIENT_SECRET='sekret~value'
  export TARGET_APP_OBJECT_ID=22222222-2222-2222-2222-222222222222
  export CURL_MOCK_TOKEN_RESPONSE='{"access_token":"fake.jwt.token"}'
  export CURL_MOCK_ADDPASSWORD_RESPONSE='{"secretText":"x"}'
  bash "$SCRIPT" >/dev/null 2>&1
  local calls
  calls=$(cat "$CALLS")
  teardown_sandbox
  assert_contains "$calls" "client_id=11111111-1111-1111-1111-111111111111" \
    && assert_contains "$calls" "grant_type=client_credentials"
}

test_uses_custom_secret_display_name() {
  setup_sandbox
  export TENANT=contoso.onmicrosoft.com
  export SP_CLIENT_ID=11111111-1111-1111-1111-111111111111
  export SP_CLIENT_SECRET='sekret~value'
  export TARGET_APP_OBJECT_ID=22222222-2222-2222-2222-222222222222
  export NEW_SECRET_NAME='my-custom-name'
  export CURL_MOCK_TOKEN_RESPONSE='{"access_token":"fake.jwt.token"}'
  export CURL_MOCK_ADDPASSWORD_RESPONSE='{"secretText":"x"}'
  bash "$SCRIPT" >/dev/null 2>&1
  local calls
  calls=$(cat "$CALLS")
  teardown_sandbox
  assert_contains "$calls" "my-custom-name"
}

test_missing_required_var_fails_fast() {
  setup_sandbox
  unset TENANT SP_CLIENT_ID SP_CLIENT_SECRET TARGET_APP_OBJECT_ID 2>/dev/null || true
  local out rc
  out=$(bash "$SCRIPT" 2>&1) && rc=0 || rc=$?
  teardown_sandbox
  [ "$rc" -ne 0 ] && assert_contains "$out" "required"
}

test_token_failure_aborts_before_addpassword_call() {
  setup_sandbox
  export TENANT=contoso.onmicrosoft.com
  export SP_CLIENT_ID=11111111-1111-1111-1111-111111111111
  export SP_CLIENT_SECRET='sekret~value'
  export TARGET_APP_OBJECT_ID=22222222-2222-2222-2222-222222222222
  # Simulate an auth failure: no access_token in the response.
  export CURL_MOCK_TOKEN_RESPONSE='{"error":"invalid_client","error_description":"bad secret"}'
  local out rc
  out=$(bash "$SCRIPT" 2>&1) && rc=0 || rc=$?
  local calls
  calls=$(cat "$CALLS")
  teardown_sandbox
  # Script must fail, and must never have reached the addPassword endpoint.
  [ "$rc" -ne 0 ] \
    && assert_contains "$out" "token request failed" \
    && ! (printf '%s' "$calls" | grep -q "graph.microsoft.com")
}

run_test "happy path prints the new secret" test_happy_path_prints_secret
run_test "client credentials passed to token request" test_passes_client_credentials_to_token_call
run_test "custom NEW_SECRET_NAME reaches addPassword call" test_uses_custom_secret_display_name
run_test "missing required env var fails fast with clear message" test_missing_required_var_fails_fast
run_test "token failure aborts before addPassword is ever called" test_token_failure_aborts_before_addpassword_call

print_summary

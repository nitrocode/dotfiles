#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-speak-summary.sh:"

HOOK="$HOOKS_DIR/speak-summary.sh"

run_with() {
  local last_msg="$1" api_key="${2:-}"
  local input
  input=$(jq -nc --arg m "$last_msg" '{last_assistant_message:$m}')
  printf '%s' "$input" | ANTHROPIC_API_KEY="$api_key" bash "$HOOK"
}

test_no_api_key_exits_zero() {
  run_with "the refactor is complete and all tests pass now" "" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

test_no_api_key_no_curl_call() {
  local sandbox; sandbox=$(mktemp -d)
  cat > "$sandbox/curl" <<'EOF'
#!/bin/bash
echo "CURL WAS CALLED" >> "$SANDBOX_MARKER"
EOF
  chmod +x "$sandbox/curl" 2>/dev/null
  export SANDBOX_MARKER="$sandbox/marker"
  PATH="$sandbox:$PATH" run_with "the refactor is complete and all tests pass now" "" >/dev/null 2>&1
  local result=1
  [ ! -f "$sandbox/marker" ] && result=0
  rm -rf "$sandbox"
  return $result
}

test_short_message_exits_zero() {
  run_with "ok" "fake-key-123" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

test_missing_last_message_exits_zero() {
  printf '%s' '{}' | ANTHROPIC_API_KEY="fake-key-123" bash "$HOOK" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

run_test "no API key -> exit 0" test_no_api_key_exits_zero
run_test "no API key -> never calls curl" test_no_api_key_no_curl_call
run_test "short message -> exit 0" test_short_message_exits_zero
run_test "missing last_assistant_message -> exit 0" test_missing_last_message_exits_zero

print_summary

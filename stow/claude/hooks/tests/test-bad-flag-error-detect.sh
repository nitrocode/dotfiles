#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-bad-flag-error-detect.sh:"

HOOK="$HOOKS_DIR/bad-flag-error-detect.sh"

run_with() {
  local cmd="$1" content="$2" session="${3:-test-session-$$}"
  local input
  input=$(jq -nc --arg c "$cmd" --arg content "$content" --arg s "$session" \
    '{tool_name:"Bash",session_id:$s,tool_input:{command:$c},tool_response:{type:"error",content:$content}}')
  printf '%s' "$input" | TMPDIR="$SANDBOX_TMPDIR" bash "$HOOK"
}

setup_sandbox() {
  SANDBOX_TMPDIR=$(mktemp -d)
}
teardown_sandbox() {
  rm -rf "$SANDBOX_TMPDIR"
}

test_unknown_option_error_suggests() {
  setup_sandbox
  local out; out=$(run_with 'somecli run --frobnicate' "error: unknown option '--frobnicate'")
  teardown_sandbox
  [ -n "$out" ] && printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1
}

test_unrecognized_flag_error_suggests() {
  setup_sandbox
  local out; out=$(run_with 'tool --nope' "Error: unrecognized flag: --nope")
  teardown_sandbox
  [ -n "$out" ] && printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1
}

test_go_flag_style_error_suggests() {
  setup_sandbox
  local out; out=$(run_with 'gotool -bogus' "flag provided but not defined: -bogus")
  teardown_sandbox
  [ -n "$out" ] && printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1
}

test_clean_success_is_silent() {
  setup_sandbox
  local out; out=$(run_with 'git status' "On branch main, nothing to commit")
  teardown_sandbox
  assert_empty "$out"
}

test_unrelated_error_is_silent() {
  setup_sandbox
  local out; out=$(run_with 'ls /nope' "ls: /nope: No such file or directory")
  teardown_sandbox
  assert_empty "$out"
}

test_dedupes_within_session() {
  setup_sandbox
  local session="dedupe-session-$$"
  local first second
  first=$(run_with 'somecli run --frobnicate' "error: unknown option '--frobnicate'" "$session")
  second=$(run_with 'somecli run --frobnicate' "error: unknown option '--frobnicate'" "$session")
  teardown_sandbox
  [ -n "$first" ] && [ -z "$second" ]
}

test_empty_command_is_silent() {
  setup_sandbox
  local out; out=$(run_with '' "error: unknown option '--x'")
  teardown_sandbox
  assert_empty "$out"
}

run_test "unknown option error suggests a rule" test_unknown_option_error_suggests
run_test "unrecognized flag error suggests a rule" test_unrecognized_flag_error_suggests
run_test "Go flag-package style error suggests a rule" test_go_flag_style_error_suggests
run_test "clean success is silent" test_clean_success_is_silent
run_test "unrelated error is silent" test_unrelated_error_is_silent
run_test "same shape in one session only warns once" test_dedupes_within_session
run_test "empty command is silent" test_empty_command_is_silent

print_summary

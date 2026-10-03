#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-scope-guard.sh:"

HOOK="$HOOKS_DIR/scope-guard.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

run_with() {
  local session="$1" file="$2"
  local input
  input=$(jq -nc --arg s "$session" --arg f "$file" '{session_id:$s, tool_input:{file_path:$f}}')
  printf '%s' "$input" | SCOPE_GUARD_STATE_DIR="$SANDBOX" bash "$HOOK"
}

test_missing_file_path_is_silent() {
  local input out
  input=$(jq -nc '{session_id:"s1", tool_input:{}}')
  out=$(printf '%s' "$input" | SCOPE_GUARD_STATE_DIR="$SANDBOX" bash "$HOOK")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_below_threshold_is_silent() {
  local out
  run_with "s2" "/a.txt" > /dev/null
  run_with "s2" "/b.txt" > /dev/null
  out=$(run_with "s2" "/c.txt")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_above_threshold_warns_once() {
  local out1 out2
  run_with "s3" "/a.txt" > /dev/null
  run_with "s3" "/b.txt" > /dev/null
  run_with "s3" "/c.txt" > /dev/null
  out1=$(run_with "s3" "/d.txt")
  assert_contains "$out1" "plan-mode.md" || return 1
  # Fifth distinct file: already warned, must stay silent.
  out2=$(run_with "s3" "/e.txt")
  assert_empty "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_repeat_edits_to_same_file_do_not_count_twice() {
  local out
  run_with "s4" "/a.txt" > /dev/null
  run_with "s4" "/a.txt" > /dev/null
  run_with "s4" "/a.txt" > /dev/null
  out=$(run_with "s4" "/a.txt")
  # Still only 1 distinct file, well under threshold.
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_missing_session_id_defaults_and_does_not_crash() {
  local input out
  input=$(jq -nc '{tool_input:{file_path:"/x.txt"}}')
  out=$(printf '%s' "$input" | SCOPE_GUARD_STATE_DIR="$SANDBOX" bash "$HOOK")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

run_test "missing file_path is silent" test_missing_file_path_is_silent
run_test "below threshold is silent" test_below_threshold_is_silent
run_test "above threshold warns once, then stays silent" test_above_threshold_warns_once
run_test "repeat edits to same file do not count twice" test_repeat_edits_to_same_file_do_not_count_twice
run_test "missing session_id defaults and does not crash" test_missing_session_id_defaults_and_does_not_crash

print_summary

#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-repeated-bash-pattern-warn.sh:"

HOOK="$HOOKS_DIR/repeated-bash-pattern-warn.sh"
STATE_ROOT="${TMPDIR:-/tmp}/repeated-bash-pattern"

new_session() {
  printf 'test-%s-%s' "$RANDOM" "$RANDOM"
}

cleanup_session() {
  rm -f "$STATE_ROOT/$1.history" "$STATE_ROOT/$1.warned" 2>/dev/null
}

run_with() {
  local cmd="$1" session="$2"
  local input
  input=$(jq -nc --arg c "$cmd" --arg s "$session" '{tool_input:{command:$c},session_id:$s}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"per-item loop"*) return 0;;
    *)
      printf '    expected a per-item-loop warning, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_two_similar_calls_silent() {
  local s; s=$(new_session)
  run_with "gh api repos/acme/foo/pulls/1/comments" "$s" >/dev/null
  local out; out=$(run_with "gh api repos/acme/foo/pulls/2/comments" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_three_similar_calls_warns() {
  local s; s=$(new_session)
  run_with "gh api repos/acme/foo/pulls/1/comments" "$s" >/dev/null
  run_with "gh api repos/acme/foo/pulls/2/comments" "$s" >/dev/null
  local out; out=$(run_with "gh api repos/acme/foo/pulls/3/comments" "$s")
  cleanup_session "$s"
  assert_warns "$out"
}

test_warns_only_once_per_shape() {
  local s; s=$(new_session)
  run_with "gh api repos/acme/foo/pulls/1/comments" "$s" >/dev/null
  run_with "gh api repos/acme/foo/pulls/2/comments" "$s" >/dev/null
  run_with "gh api repos/acme/foo/pulls/3/comments" "$s" >/dev/null
  local out; out=$(run_with "gh api repos/acme/foo/pulls/4/comments" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_different_commands_dont_accumulate() {
  local s; s=$(new_session)
  run_with "git status" "$s" >/dev/null
  run_with "ls -la" "$s" >/dev/null
  local out; out=$(run_with "git diff" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_missing_command_fails_open() {
  local input='{"session_id":"test-missing-cmd"}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_missing_session_id_fails_open() {
  local input='{"tool_input":{"command":"echo hi"}}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

run_test "2x similar calls -> silent" test_two_similar_calls_silent
run_test "3x similar calls -> warns" test_three_similar_calls_warns
run_test "4th repeat -> silent (already warned)" test_warns_only_once_per_shape
run_test "different commands don't accumulate" test_different_commands_dont_accumulate
run_test "missing command -> fails open" test_missing_command_fails_open
run_test "missing session_id -> fails open" test_missing_session_id_fails_open

print_summary

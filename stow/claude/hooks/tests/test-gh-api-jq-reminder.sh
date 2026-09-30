#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-gh-api-jq-reminder.sh:"

HOOK="$HOOKS_DIR/gh-api-jq-reminder.sh"

run_with() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"--jq"*) return 0;;
    *)
      printf '    expected a --jq reminder, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_gh_api_no_jq_warns() {
  local out; out=$(run_with 'gh api /repos/acme/foo/pulls')
  assert_warns "$out"
}

test_gh_api_with_jq_silent() {
  local out; out=$(run_with 'gh api /repos/acme/foo/pulls --jq ".[].number"')
  assert_empty "$out"
}

test_gh_api_post_mutation_no_jq_warns() {
  local out; out=$(run_with 'gh api --method POST /repos/acme/foo/issues/1/comments -f body=hi')
  assert_warns "$out"
}

test_gh_pr_list_silent() {
  local out; out=$(run_with 'gh pr list')
  assert_empty "$out"
}

test_gh_apiary_lookalike_silent() {
  local out; out=$(run_with 'gh apiary status')
  assert_empty "$out"
}

test_gh_api_chained_after_semicolon_warns() {
  local out; out=$(run_with 'cd /tmp && gh api /rate_limit')
  assert_warns "$out"
}

test_unrelated_command_silent() {
  local out; out=$(run_with 'ls -la')
  assert_empty "$out"
}

test_empty_command_silent() {
  local out; out=$(printf '%s' '{"tool_name":"Bash","tool_input":{}}' | bash "$HOOK")
  assert_empty "$out"
}

run_test "gh api no --jq -> warns" test_gh_api_no_jq_warns
run_test "gh api --jq -> silent" test_gh_api_with_jq_silent
run_test "gh api POST mutation no --jq -> warns" test_gh_api_post_mutation_no_jq_warns
run_test "gh pr list -> silent" test_gh_pr_list_silent
run_test "gh apiary lookalike -> silent" test_gh_apiary_lookalike_silent
run_test "chained gh api after && -> warns" test_gh_api_chained_after_semicolon_warns
run_test "unrelated command -> silent" test_unrelated_command_silent
run_test "empty command -> silent" test_empty_command_silent

print_summary

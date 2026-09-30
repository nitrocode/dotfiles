#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-bulk-op-preflight.sh:"

HOOK="$HOOKS_DIR/bulk-op-preflight.sh"

run_with() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg cmd "$cmd" '{tool_input:{command:$cmd},cwd:"/tmp"}')
  printf '%s' "$input" | bash "$HOOK"
}

test_xargs_rm_warns() {
  local out
  out=$(run_with 'cat ids.txt | xargs -I {} aws s3api delete-object --bucket b --key {}')
  assert_decision "$out" "ask"
}

test_for_loop_close_warns() {
  local out
  out=$(run_with 'for issue in $(cat list); do gh issue close "$issue" --comment "stale"; done')
  assert_decision "$out" "ask"
}

test_granted_populate_warns() {
  local out
  out=$(run_with 'granted sso populate --sso-region us-east-1')
  assert_decision "$out" "ask"
}

test_jira_bulk_transition_warns() {
  local out
  out=$(run_with 'for k in $(cat keys); do jira issue transition "$k" "Done"; done')
  assert_decision "$out" "ask"
}

test_dry_run_flag_silent() {
  local out
  out=$(run_with 'for k in $(cat keys); do jira issue transition "$k" "Done" --dry-run; done')
  assert_empty "$out"
}

test_read_only_for_loop_silent() {
  local out
  out=$(run_with 'for f in $(ls *.log); do grep ERROR "$f"; done')
  assert_empty "$out"
}

test_short_command_silent() {
  local out
  out=$(run_with 'rm foo')
  assert_empty "$out"
}

test_empty_command_silent() {
  local input='{"tool_input":{},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_single_aws_delete_silent() {
  # Single aws delete is not bulk (no wrapper).
  local out
  out=$(run_with 'aws s3 rm s3://my-bucket/some-prefix-that-is-long-enough')
  assert_empty "$out"
}

test_xargs_read_only_silent() {
  local out
  out=$(run_with 'cat repos.txt | xargs -I {} gh repo view {}')
  assert_empty "$out"
}

test_small_literal_list_silent() {
  # Literal, statically-countable list under the 10-item threshold.
  local out
  out=$(run_with 'for issue in ABC-1 ABC-2 ABC-3; do jira issue transition "$issue" Done; done')
  assert_empty "$out"
}

test_large_literal_list_warns() {
  # Literal list at/above the 10-item threshold still warns.
  local out
  out=$(run_with 'for issue in ABC-1 ABC-2 ABC-3 ABC-4 ABC-5 ABC-6 ABC-7 ABC-8 ABC-9 ABC-10 ABC-11 ABC-12; do jira issue transition "$issue" Done; done')
  assert_decision "$out" "ask"
}

test_small_brace_range_silent() {
  local out
  out=$(run_with 'for i in {1..5}; do rm "file-$i.tmp"; done')
  assert_empty "$out"
}

test_large_brace_range_warns() {
  local out
  out=$(run_with 'for i in {1..20}; do rm "file-$i.tmp"; done')
  assert_decision "$out" "ask"
}

test_small_brace_list_silent() {
  local out
  out=$(run_with 'for env in dev staging prod; do rm "artifact-$env.tmp"; done')
  assert_empty "$out"
}

test_unknown_size_for_loop_still_warns() {
  # A for-loop sourced from command substitution has no statically knowable
  # count, so it must still trigger the reminder even though it's short in
  # this example -- undercounting here would defeat the purpose of the gate.
  local out
  out=$(run_with 'for issue in $(cat list); do gh issue close "$issue" --comment "stale"; done')
  assert_decision "$out" "ask"
}

run_test "xargs + aws delete -> ask" test_xargs_rm_warns
run_test "for-loop + gh issue close -> ask" test_for_loop_close_warns
run_test "granted sso populate -> ask" test_granted_populate_warns
run_test "for-loop + jira transition -> ask" test_jira_bulk_transition_warns
run_test "--dry-run present -> silent" test_dry_run_flag_silent
run_test "for-loop with read-only verb -> silent" test_read_only_for_loop_silent
run_test "short command -> silent" test_short_command_silent
run_test "empty command -> silent" test_empty_command_silent
run_test "single aws delete (no wrapper) -> silent" test_single_aws_delete_silent
run_test "xargs + read-only verb -> silent" test_xargs_read_only_silent
run_test "literal list < 10 items -> silent" test_small_literal_list_silent
run_test "literal list >= 10 items -> ask" test_large_literal_list_warns
run_test "brace numeric range < 10 -> silent" test_small_brace_range_silent
run_test "brace numeric range >= 10 -> ask" test_large_brace_range_warns
run_test "brace comma list < 10 -> silent" test_small_brace_list_silent
run_test "unknown-size for-loop (command subst) -> ask" test_unknown_size_for_loop_still_warns

print_summary

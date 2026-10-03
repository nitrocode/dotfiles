#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-known-bad-flag-block.sh:"

HOOK="$HOOKS_DIR/known-bad-flag-block.sh"

# The hook hardcodes $CLAUDE_CONFIG_DIR/hooks/bad-flag-rules.tsv, so tests run
# against the real, live rules file rather than a fixture -- exercising the
# actual shipped coderabbit rule plus generic true/false cases that don't
# depend on rules-file content beyond what's already there.
run_live() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$input" | bash "$HOOK"
}

test_coderabbit_plain_denies() {
  local out; out=$(run_live 'coderabbit review --plain')
  assert_decision "$out" "deny"
}

test_coderabbit_bare_review_is_silent() {
  local out; out=$(run_live 'coderabbit review')
  assert_empty "$out"
}

test_unrelated_command_is_silent() {
  local out; out=$(run_live 'git status')
  assert_empty "$out"
}

test_command_matches_but_flag_does_not_is_silent() {
  local out; out=$(run_live 'coderabbit review --agent')
  assert_empty "$out"
}

test_empty_command_is_silent() {
  local out; out=$(run_live '')
  assert_empty "$out"
}

test_missing_rules_file_fails_open() {
  local sandbox out
  sandbox=$(mktemp -d)
  local input
  input=$(jq -nc --arg c 'coderabbit review --plain' '{tool_name:"Bash",tool_input:{command:$c}}')
  out=$(printf '%s' "$input" | HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK")
  rm -rf "$sandbox"
  assert_empty "$out"
}

test_custom_rule_denies() {
  # Exercises a second, non-coderabbit rule to prove genericity: a fixture
  # rules file under a fake $HOME, unrelated to the real coderabbit rule.
  local sandbox out
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/hooks"
  printf 'foo[[:space:]]+bar\t--baz([[:space:]]|$)\tfoo bar has no --baz flag.\n' > "$sandbox/.claude/hooks/bad-flag-rules.tsv"
  local input
  input=$(jq -nc --arg c 'foo bar --baz' '{tool_name:"Bash",tool_input:{command:$c}}')
  out=$(printf '%s' "$input" | HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK")
  rm -rf "$sandbox"
  assert_decision "$out" "deny"
}

run_test "coderabbit review --plain denies (live rule)" test_coderabbit_plain_denies
run_test "bare coderabbit review is silent" test_coderabbit_bare_review_is_silent
run_test "unrelated command is silent" test_unrelated_command_is_silent
run_test "command matches but flag doesn't is silent" test_command_matches_but_flag_does_not_is_silent
run_test "empty command is silent" test_empty_command_is_silent
run_test "missing rules file fails open" test_missing_rules_file_fails_open
run_test "a generic non-coderabbit rule denies" test_custom_rule_denies

print_summary

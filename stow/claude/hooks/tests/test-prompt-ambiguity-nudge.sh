#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-prompt-ambiguity-nudge.sh:"

HOOK="$HOOKS_DIR/prompt-ambiguity-nudge.sh"

run_with() {
  local prompt="$1"
  local input
  input=$(jq -nc --arg p "$prompt" '{user_prompt:$p,session_id:"test"}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_nudges() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$body" in
    *"plan-mode"*) return 0;;
    *)
      printf '    expected a plan-mode nudge, got: %s\n' "$(printf '%s' "$body" | head -c 300)" >&2
      return 1
      ;;
  esac
}

test_how_should_we_prompt_nudges() {
  local out; out=$(run_with 'how should we set up a people registry for who to contact and when')
  assert_nudges "$out"
}

test_figure_out_prompt_nudges() {
  local out; out=$(run_with 'can you figure out how we should track vendor renewal dates across the team')
  assert_nudges "$out"
}

test_build_registry_prompt_nudges() {
  local out; out=$(run_with 'we need a way to build a registry system for tracking who owns what')
  assert_nudges "$out"
}

test_concrete_file_prompt_silent() {
  local out; out=$(run_with 'how should we set up the config in settings.json for this feature')
  assert_empty "$out"
}

test_backticked_target_prompt_silent() {
  local out; out=$(run_with 'figure out how we should handle the `retry_count` field in this module')
  assert_empty "$out"
}

test_short_prompt_silent() {
  local out; out=$(run_with 'how should we do this')
  assert_empty "$out"
}

test_informational_question_silent() {
  local out; out=$(run_with 'what is the best way people usually describe event sourcing architecture')
  assert_empty "$out"
}

test_unrelated_prompt_silent() {
  local out; out=$(run_with 'run the test suite and tell me if anything fails')
  assert_empty "$out"
}

test_empty_prompt_silent() {
  local input='{"user_prompt":""}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_case_insensitive() {
  local out; out=$(run_with 'HOW SHOULD WE HANDLE THIS across every team in the org going forward')
  assert_nudges "$out"
}

run_test "how should we -> nudge" test_how_should_we_prompt_nudges
run_test "figure out how -> nudge" test_figure_out_prompt_nudges
run_test "build a registry system -> nudge" test_build_registry_prompt_nudges
run_test "concrete file named -> silent" test_concrete_file_prompt_silent
run_test "backticked identifier named -> silent" test_backticked_target_prompt_silent
run_test "short prompt -> silent" test_short_prompt_silent
run_test "informational question -> silent" test_informational_question_silent
run_test "unrelated concrete ask -> silent" test_unrelated_prompt_silent
run_test "empty prompt -> silent" test_empty_prompt_silent
run_test "case-insensitive match" test_case_insensitive

print_summary

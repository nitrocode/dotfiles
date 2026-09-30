#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-skill-suggest.sh:"

HOOK="$HOOKS_DIR/skill-suggest.sh"

run_with() {
  local prompt="$1"
  local input
  input=$(jq -nc --arg p "$prompt" '{user_prompt:$p,session_id:"test"}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_suggests() {
  local actual="$1" needle="$2"
  local body
  body=$(printf '%s' "$actual" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$body" in
    *"$needle"*) return 0;;
    *)
      printf '    expected suggestion to contain %s\n    got: %s\n' "$needle" "$(printf '%s' "$body" | head -c 300)" >&2
      return 1
      ;;
  esac
}

test_security_prompt_suggests_sec_review() {
  local out; out=$(run_with 'is this code sus from a security perspective?')
  assert_suggests "$out" "/sec-review"
}

test_owasp_prompt_suggests_sec_review() {
  local out; out=$(run_with 'check for OWASP issues in this PR')
  assert_suggests "$out" "/sec-review"
}

test_slack_draft_prompt_suggests() {
  local out; out=$(run_with 'draft a slack message to the team about the migration')
  assert_suggests "$out" "/slack-draft"
}

test_review_feedback_prompt_suggests_cr_response() {
  local out; out=$(run_with 'address coderabbit feedback on PR 123')
  assert_suggests "$out" "cr-response"
}

test_bulk_prompt_suggests_dry_run() {
  local out; out=$(run_with 'close all stale tickets older than 90 days')
  assert_suggests "$out" "dry-run"
}

test_datadog_prompt_suggests_mcp() {
  local out; out=$(run_with 'show me datadog dashboards for the api service')
  assert_suggests "$out" "datadog MCP"
}

test_jira_epic_prompt_suggests_epic_link() {
  local out; out=$(run_with 'find children of jira epic PROJ-1234')
  assert_suggests "$out" "Epic Link"
}

test_atmos_prompt_suggests_describe() {
  local out; out=$(run_with 'why is the atmos terraform plan showing <no value>?')
  assert_suggests "$out" "atmos describe"
}

test_unrelated_prompt_silent() {
  local out; out=$(run_with 'what is the capital of france')
  assert_empty "$out"
}

test_empty_prompt_silent() {
  local input='{"user_prompt":""}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_multiple_keywords_dedupe() {
  # "security" and "owasp" both should map to /sec-review; suggestion line should appear once.
  local out body
  out=$(run_with 'do an owasp security review for vuln scanning')
  body=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  local count
  count=$(printf '%s' "$body" | grep -c '/sec-review skill (OWASP')
  if [ "$count" -eq 1 ]; then
    return 0
  fi
  printf '    expected 1 deduped suggestion line, got %d\n' "$count" >&2
  return 1
}

test_case_insensitive() {
  local out; out=$(run_with 'DRAFT A SLACK ANNOUNCEMENT FOR LEADERSHIP')
  assert_suggests "$out" "/slack-draft"
}

run_test "security keyword -> /sec-review" test_security_prompt_suggests_sec_review
run_test "owasp keyword -> /sec-review" test_owasp_prompt_suggests_sec_review
run_test "slack draft phrase -> /slack-draft" test_slack_draft_prompt_suggests
run_test "coderabbit feedback -> cr-response" test_review_feedback_prompt_suggests_cr_response
run_test "bulk close phrase -> dry-run reminder" test_bulk_prompt_suggests_dry_run
run_test "datadog -> datadog MCP" test_datadog_prompt_suggests_mcp
run_test "jira epic -> Epic Link reminder" test_jira_epic_prompt_suggests_epic_link
run_test "atmos <no value> -> describe component" test_atmos_prompt_suggests_describe
run_test "unrelated prompt -> silent" test_unrelated_prompt_silent
run_test "empty prompt -> silent" test_empty_prompt_silent
run_test "duplicate keywords -> single suggestion line" test_multiple_keywords_dedupe
run_test "case-insensitive match" test_case_insensitive

print_summary

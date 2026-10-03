#!/bin/bash
# Tests for no-em-dashes-pretool.py: PreToolUse hook that rewrites em dashes
# (U+2014) to ", " in text-content tools (file writes, Slack, Jira,
# Confluence) and allows the call with the corrected payload (modifiedInput).
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

HOOK="$HOOKS_DIR/no-em-dashes-pretool.py"

echo "test-no-em-dashes-pretool.sh:"

# Construct the em-dash byte at runtime so this file stays em-dash-free (and
# so the hook itself doesn't rewrite the fixtures when this file is edited).
DASH=$(printf '\xe2\x80\x94')

run_hook() {
  local event="$1"
  printf '%s' "$event" | python3 "$HOOK"
}

# assert_rewritten OUT JQ_PATH EXPECTED: decision is allow, the field at
# JQ_PATH in modifiedInput equals EXPECTED, and no em dash is left outside
# fenced code in the corrected payload.
assert_rewritten() {
  local out="$1" path="$2" expected="$3" got
  assert_decision "$out" "allow" || return 1
  got=$(printf '%s' "$out" | jq -r ".hookSpecificOutput.modifiedInput$path")
  if [ "$got" != "$expected" ]; then
    printf '    expected modifiedInput%s=%s, got=%s\n' "$path" "$expected" "$got" >&2
    return 1
  fi
}

# event TOOL JSON_TOOL_INPUT_WITH_$d: build a hook event, $d bound to the em dash.
event() {
  jq -nc --arg d "$DASH" --arg t "$1" "{tool_name:\$t,tool_input:($2)}"
}

test_slack_send_rewritten() {
  local out; out=$(run_hook "$(event mcp__plugin_slack_slack__slack_send_message '{channel_id:"C123",text:("Hello " + $d + " world")}')")
  assert_rewritten "$out" .text "Hello, world"
}

test_slack_draft_rewritten() {
  local out; out=$(run_hook "$(event mcp__plugin_slack_slack__slack_send_message_draft '{channel_id:"C1",message:("foo " + $d + " bar")}')")
  assert_rewritten "$out" .message "foo, bar"
}

test_jira_comment_rewritten() {
  local out; out=$(run_hook "$(event mcp__plugin_atlassian_atlassian__addCommentToJiraIssue '{issueIdOrKey:"PROJ-1",commentBody:("Note " + $d + " important")}')")
  assert_rewritten "$out" .commentBody "Note, important"
}

test_edit_new_string_rewritten() {
  local out; out=$(run_hook "$(event Edit '{file_path:"/tmp/foo.md",old_string:"x",new_string:("y " + $d + " z")}')")
  assert_rewritten "$out" .new_string "y, z"
}

test_write_content_rewritten() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:("A " + $d + " B")}')")
  assert_rewritten "$out" .content "A, B"
}

test_multiedit_nested_rewritten() {
  local out; out=$(run_hook "$(event MultiEdit '{file_path:"/tmp/foo.md",edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:("d " + $d + " e")}]}')")
  assert_rewritten "$out" '.edits[1].new_string' "d, e" \
    && assert_rewritten "$out" '.edits[0].new_string' "b"
}

test_confluence_body_rewritten() {
  local out; out=$(run_hook "$(event mcp__plugin_atlassian_atlassian__updateConfluencePage '{pageId:"123",body:("<p>hello " + $d + " world</p>")}')")
  assert_rewritten "$out" .body "<p>hello, world</p>"
}

# Em dash INSIDE a fenced code block is preserved, so nothing to rewrite.
test_em_dash_in_fenced_code_allowed() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:("plain text\n```\nliteral " + $d + " preserved\n```\nmore plain")}')")
  assert_empty "$out"
}

test_plain_ascii_allowed() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:"Just plain ASCII text, no dashes here."}')")
  assert_empty "$out"
}

test_non_watched_tool_allowed() {
  local out; out=$(run_hook "$(event Bash '{command:("echo a " + $d + " b")}')")
  assert_empty "$out"
}

test_spaced_em_dash_collapses_spaces() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:("left " + $d + " right")}')")
  assert_rewritten "$out" .content "left, right"
}

test_bare_em_dash_becomes_comma_space() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:("left" + $d + "right")}')")
  assert_rewritten "$out" .content "left, right"
}

# Prose em dash is rewritten while the fenced one is kept verbatim.
test_outside_fence_rewritten_inside_kept() {
  local out
  out=$(run_hook "$(event Write '{file_path:"/tmp/foo.md",content:("prose " + $d + " here\n```\ncode " + $d + " preserved\n```\n")}')")
  assert_rewritten "$out" .content "prose, here
\`\`\`
code $DASH preserved
\`\`\`"
}

test_empty_tool_input_allowed() {
  local out; out=$(run_hook "$(event Write '{}')")
  assert_empty "$out"
}

test_edit_em_dash_in_old_string_only_allowed() {
  local out; out=$(run_hook "$(event Edit '{file_path:"/tmp/foo.md",old_string:("matches " + $d + " existing"),new_string:"plain replacement"}')")
  assert_empty "$out"
}

test_multiedit_em_dash_in_old_string_only_allowed() {
  local out; out=$(run_hook "$(event MultiEdit '{file_path:"/tmp/foo.md",edits:[{old_string:("x " + $d + " y"),new_string:"clean"}]}')")
  assert_empty "$out"
}

# old_string is read-only (must still match the file), so only new_string changes.
test_edit_both_fields_corrects_new_only() {
  local out; out=$(run_hook "$(event Edit '{file_path:"/tmp/foo.md",old_string:("existing " + $d + " match"),new_string:("replacement " + $d + " bad")}')")
  assert_rewritten "$out" .new_string "replacement, bad" \
    && assert_rewritten "$out" .old_string "existing $DASH match"
}

test_write_plans_dir_exempt() {
  local out p="$CLAUDE_CONFIG_DIR/plans/foo.md"
  out=$(run_hook "$(jq -nc --arg p "$p" --arg d "$DASH" '{tool_name:"Write",tool_input:{file_path:$p,content:("A " + $d + " B")}}')")
  assert_empty "$out"
}

# The config dir can be a symlink; the resolved (physical) plans path is exempt too.
test_write_plans_dir_physical_path_exempt() {
  local out p
  p="$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)/plans/foo.md"
  out=$(run_hook "$(jq -nc --arg p "$p" --arg d "$DASH" '{tool_name:"Write",tool_input:{file_path:$p,content:("A " + $d + " B")}}')")
  assert_empty "$out"
}

test_edit_scratchpad_dir_exempt() {
  local out; out=$(run_hook "$(event Edit '{file_path:"/private/tmp/claude-502/sess/scratchpad/notes.md",old_string:"x",new_string:("y " + $d + " z")}')")
  assert_empty "$out"
}

test_multiedit_scratchpad_dir_exempt() {
  local out; out=$(run_hook "$(event MultiEdit '{file_path:"/tmp/x/scratchpad/notes.md",edits:[{old_string:"a",new_string:("b " + $d + " c")}]}')")
  assert_empty "$out"
}

# Only the exact plans prefix and the /scratchpad/ substring qualify.
test_similar_but_non_exempt_path_rewritten() {
  local out; out=$(run_hook "$(event Write '{file_path:"/tmp/not-plans/foo.md",content:("A " + $d + " B")}')")
  assert_rewritten "$out" .content "A, B"
}

# The exemption is for file tools only, even if a file_path-shaped field is present.
test_exemption_does_not_apply_to_slack() {
  local out; out=$(run_hook "$(event mcp__plugin_slack_slack__slack_send_message '{channel_id:"C123",text:("Hello " + $d + " world"),file_path:"/private/x/scratchpad/y.md"}')")
  assert_rewritten "$out" .text "Hello, world"
}

run_test "slack send: em dash rewritten" test_slack_send_rewritten
run_test "slack draft: em dash rewritten" test_slack_draft_rewritten
run_test "jira comment: em dash rewritten" test_jira_comment_rewritten
run_test "edit: em dash in new_string rewritten" test_edit_new_string_rewritten
run_test "write: em dash in content rewritten" test_write_content_rewritten
run_test "multiedit: nested edit rewritten, others untouched" test_multiedit_nested_rewritten
run_test "confluence: em dash in body rewritten" test_confluence_body_rewritten
run_test "em dash inside fenced code: allowed" test_em_dash_in_fenced_code_allowed
run_test "plain ascii: allowed" test_plain_ascii_allowed
run_test "non-watched tool (bash): allowed" test_non_watched_tool_allowed
run_test "spaced em dash: collapses to ', '" test_spaced_em_dash_collapses_spaces
run_test "bare em dash: becomes ', '" test_bare_em_dash_becomes_comma_space
run_test "prose rewritten, fenced em dash kept" test_outside_fence_rewritten_inside_kept
run_test "empty tool_input: allowed" test_empty_tool_input_allowed
run_test "edit: em dash in old_string only allowed" test_edit_em_dash_in_old_string_only_allowed
run_test "multiedit: em dash in old_string only allowed" test_multiedit_em_dash_in_old_string_only_allowed
run_test "edit: both fields, corrects new_string only" test_edit_both_fields_corrects_new_only
run_test "write: plans dir exempt" test_write_plans_dir_exempt
run_test "write: plans dir exempt via physical path" test_write_plans_dir_physical_path_exempt
run_test "edit: scratchpad dir exempt" test_edit_scratchpad_dir_exempt
run_test "multiedit: scratchpad dir exempt" test_multiedit_scratchpad_dir_exempt
run_test "write: similar but non-exempt path rewritten" test_similar_but_non_exempt_path_rewritten
run_test "exemption does not apply to slack tools" test_exemption_does_not_apply_to_slack

print_summary

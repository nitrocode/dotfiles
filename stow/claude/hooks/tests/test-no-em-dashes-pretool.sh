#!/bin/bash
# Tests for no-em-dashes-pretool.py — PreToolUse blocker for em dashes (U+2014)
# in tool inputs to text-content tools (file writes, Slack, Jira, Confluence).
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

HOOK="$HOOKS_DIR/no-em-dashes-pretool.py"

echo "test-no-em-dashes-pretool.sh:"

run_hook() {
  local event="$1"
  printf '%s' "$event" | python3 "$HOOK"
}

# Slack message with em dash blocks.
test_slack_send_message_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"mcp__plugin_slack_slack__slack_send_message",tool_input:{channel_id:"C123",text:"Hello — world"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny" || return 1
  assert_contains "$out" "U+2014"
}

# Construct an em-dash byte at runtime so this test file source stays em-dash-free.
DASH=$(printf '\xe2\x80\x94')

# Edit with em dash ONLY in old_string (read-only field) is allowed.
test_edit_em_dash_in_old_string_only_allowed() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"Edit",tool_input:{file_path:"/tmp/foo.md",old_string:("matches " + $d + " existing"),new_string:"plain replacement"}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# MultiEdit with em dash ONLY in edits[].old_string is allowed.
test_multiedit_em_dash_in_old_string_only_allowed() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"MultiEdit",tool_input:{file_path:"/tmp/foo.md",edits:[{old_string:("x " + $d + " y"),new_string:"clean"}]}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Edit with em dash in BOTH old_string and new_string still blocks; corrected new_string only.
test_edit_em_dash_in_both_old_and_new_blocks() {
  local event out reason
  event=$(jq -nc --arg d "$DASH" '{tool_name:"Edit",tool_input:{file_path:"/tmp/foo.md",old_string:("existing " + $d + " match"),new_string:("replacement " + $d + " bad")}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny" || return 1
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # old_string preserved with the em dash bytes intact
  echo "$reason" | grep -q "existing $DASH match" || { echo "old_string should be unchanged in corrected output"; return 1; }
  assert_contains "$reason" "replacement, bad"
}

# Slack draft with em dash blocks and includes corrected text.
test_slack_draft_em_dash_blocks_with_corrected_text() {
  local event out reason
  event=$(jq -nc '{tool_name:"mcp__plugin_slack_slack__slack_send_message_draft",tool_input:{channel_id:"C1",message:"foo — bar"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny" || return 1
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  assert_contains "$reason" "foo, bar"
}

# Jira comment body with em dash blocks.
test_jira_comment_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"mcp__plugin_atlassian_atlassian__addCommentToJiraIssue",tool_input:{issueIdOrKey:"PROJ-1",commentBody:"Note — important"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Edit tool with em dash in new_string blocks.
test_edit_new_string_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/tmp/foo.md",old_string:"x",new_string:"y — z"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Write tool with em dash in content blocks.
test_write_content_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"A — B"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# MultiEdit with em dash in nested edits[] blocks.
test_multiedit_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"MultiEdit",tool_input:{file_path:"/tmp/foo.md",edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:"d — e"}]}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Confluence page update with em dash in body blocks.
test_confluence_page_em_dash_blocks() {
  local event out
  event=$(jq -nc '{tool_name:"mcp__plugin_atlassian_atlassian__updateConfluencePage",tool_input:{pageId:"123",body:"<p>hello — world</p>"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Em dash INSIDE a fenced code block is allowed (passed through unchanged).
test_em_dash_in_fenced_code_allowed() {
  local event out
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"plain text\n```\nliteral — preserved\n```\nmore plain"}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Plain ASCII text passes through.
test_plain_ascii_allowed() {
  local event out
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"Just plain ASCII text, no dashes here."}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Non-watched tool (Bash) passes through even with em dash.
test_non_watched_tool_allowed() {
  local event out
  event=$(jq -nc '{tool_name:"Bash",tool_input:{command:"echo a — b"}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Spaced em dash collapses to ", " (no double space).
test_spaced_em_dash_collapses_spaces() {
  local event out reason
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"left — right"}}')
  out=$(run_hook "$event")
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  assert_contains "$reason" "left, right"
}

# Bare em dash (no surrounding spaces) becomes ", ".
test_bare_em_dash_becomes_comma_space() {
  local event out reason
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"left—right"}}')
  out=$(run_hook "$event")
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  assert_contains "$reason" "left, right"
}

# Mixed: em dash outside fences blocks even when fenced em dash exists.
test_em_dash_outside_fence_blocks_when_fence_also_has_one() {
  local event out
  event=$(jq -nc '{tool_name:"Write",tool_input:{file_path:"/tmp/foo.md",content:"prose — here\n```\ncode — preserved\n```\n"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Empty / missing tool_input passes through.
test_empty_tool_input_allowed() {
  local event out
  event=$(jq -nc '{tool_name:"Write",tool_input:{}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Write to ~/.claude/plans/ is exempt even with an em dash in content.
test_write_plans_dir_exempt() {
  local event out plans_path
  plans_path="$CLAUDE_CONFIG_DIR/plans/foo.md"
  event=$(jq -nc --arg p "$plans_path" --arg d "$DASH" '{tool_name:"Write",tool_input:{file_path:$p,content:("A " + $d + " B")}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# Edit to a session scratchpad dir is exempt even with an em dash in new_string.
test_edit_scratchpad_dir_exempt() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"Edit",tool_input:{file_path:"/private/tmp/claude-502/sess/scratchpad/notes.md",old_string:"x",new_string:("y " + $d + " z")}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# MultiEdit to a scratchpad dir is exempt.
test_multiedit_scratchpad_dir_exempt() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"MultiEdit",tool_input:{file_path:"/tmp/x/scratchpad/notes.md",edits:[{old_string:"a",new_string:("b " + $d + " c")}]}}')
  out=$(run_hook "$event")
  assert_empty "$out"
}

# A plans-like path outside the real ~/.claude/plans/ prefix is NOT exempt
# (only the exact prefix and the /scratchpad/ substring qualify).
test_write_similar_but_non_exempt_path_still_blocks() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"Write",tool_input:{file_path:"/tmp/not-plans/foo.md",content:("A " + $d + " B")}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

# Exemption does not extend to non-file-path tools (Slack/Jira/Confluence)
# even if a file_path-shaped field happened to be present.
test_exemption_does_not_apply_to_slack() {
  local event out
  event=$(jq -nc --arg d "$DASH" '{tool_name:"mcp__plugin_slack_slack__slack_send_message",tool_input:{channel_id:"C123",text:("Hello " + $d + " world"),file_path:"/private/x/scratchpad/y.md"}}')
  out=$(run_hook "$event")
  assert_decision "$out" "deny"
}

run_test "slack send: em dash blocks" test_slack_send_message_em_dash_blocks
run_test "slack draft: em dash blocks with corrected text" test_slack_draft_em_dash_blocks_with_corrected_text
run_test "jira comment: em dash blocks" test_jira_comment_em_dash_blocks
run_test "edit: em dash in new_string blocks" test_edit_new_string_em_dash_blocks
run_test "write: em dash in content blocks" test_write_content_em_dash_blocks
run_test "multiedit: em dash in nested edits blocks" test_multiedit_em_dash_blocks
run_test "confluence: em dash in body blocks" test_confluence_page_em_dash_blocks
run_test "em dash inside fenced code: allowed" test_em_dash_in_fenced_code_allowed
run_test "plain ascii: allowed" test_plain_ascii_allowed
run_test "non-watched tool (bash): allowed" test_non_watched_tool_allowed
run_test "spaced em dash: collapses to ', '" test_spaced_em_dash_collapses_spaces
run_test "bare em dash: becomes ', '" test_bare_em_dash_becomes_comma_space
run_test "em dash outside fence blocks even with fenced one" test_em_dash_outside_fence_blocks_when_fence_also_has_one
run_test "empty tool_input: allowed" test_empty_tool_input_allowed
run_test "edit: em dash in old_string only allowed" test_edit_em_dash_in_old_string_only_allowed
run_test "multiedit: em dash in old_string only allowed" test_multiedit_em_dash_in_old_string_only_allowed
run_test "edit: em dash in both old and new blocks, corrects new only" test_edit_em_dash_in_both_old_and_new_blocks
run_test "write: ~/.claude/plans/ path exempt" test_write_plans_dir_exempt
run_test "edit: scratchpad dir path exempt" test_edit_scratchpad_dir_exempt
run_test "multiedit: scratchpad dir path exempt" test_multiedit_scratchpad_dir_exempt
run_test "write: similar but non-exempt path still blocks" test_write_similar_but_non_exempt_path_still_blocks
run_test "exemption does not apply to slack tools" test_exemption_does_not_apply_to_slack

print_summary

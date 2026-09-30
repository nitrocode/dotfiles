#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-session-ledger-check.sh:"

HOOK="$HOOKS_DIR/session-ledger-check.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

write_transcript() {
  local path="$1"; shift
  printf '%s\n' "$@" > "$path"
}

run_with() {
  local transcript="$1"
  printf '{}' | SESSION_LEDGER_TRANSCRIPT="$transcript" bash "$HOOK"
}

test_no_transcript_is_silent() {
  local out
  out=$(printf '{}' | SESSION_LEDGER_TRANSCRIPT="$SANDBOX/does-not-exist.jsonl" bash "$HOOK")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_no_taskcreate_is_silent() {
  local t out
  t="$SANDBOX/no-taskcreate.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"All done, no ledger needed."}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_taskcreate_without_ledger_warns() {
  local t out
  t="$SANDBOX/taskcreate-no-ledger.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"All finished, everything shipped."}]}}'
  out=$(run_with "$t")
  assert_contains "$out" "session-closeout.md"
}

test_taskcreate_with_ledger_is_silent() {
  local t out
  t="$SANDBOX/taskcreate-with-ledger.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DONE: shipped the PR.\nNOT DONE: Jira ticket still needs approval.\nUNVERIFIED: none."}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_bare_done_without_colon_is_silent() {
  # Regression test: an all-clear closeout doesn't always use a colon
  # ("DONE, nothing pending." / "DONE, all clear"). The original
  # '^done:' pattern required the colon literally, so these false-positived
  # into a warning on every single turn despite a genuine all-clear reply.
  local t out
  t="$SANDBOX/bare-done.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DONE, nothing pending."}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_markdown_bold_done_is_silent() {
  # Regression test for the production bug: "**DONE**: ..." starts with
  # markdown bold asterisks, not the literal characters "done", so the
  # anchored `^done\b` pattern never matched and the hook re-fired on every
  # turn of a session, even when every reply properly closed out with DONE.
  local t out
  t="$SANDBOX/markdown-bold-done.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"**DONE**: all 6 tools installed and verified."}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_done_mid_sentence_still_warns() {
  # The word-boundary fix must not turn into an unanchored match, "done"
  # appearing mid-sentence in an otherwise-vague reply should still warn.
  local t out
  t="$SANDBOX/done-mid-sentence.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"I think we are done here, looks good overall."}]}}'
  out=$(run_with "$t")
  assert_contains "$out" "session-closeout.md"
}

test_ledger_not_on_final_line_is_still_silent() {
  # Regression test: a real reply is multi-paragraph, and the ledger section
  # often sits above a closing question/remark, not on the literal last line.
  # jq -r expands the embedded \n into real stdout lines, so a naive
  # `tail -n 1` after that only sees the trailing sentence and misses the
  # ledger entirely. This is the exact false-positive observed in production.
  local t out
  t="$SANDBOX/ledger-not-last-line.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DONE: shipped the PR.\nNOT DONE: Jira ticket still needs approval.\nUNVERIFIED: none.\n\nLet me know if you want to continue."}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_checks_last_message_not_first() {
  local t out
  t="$SANDBOX/checks-last.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"NOT DONE: early note, superseded."}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrapped up, all good."}]}}'
  out=$(run_with "$t")
  assert_contains "$out" "session-closeout.md"
}

run_with_lam() {
  local transcript="$1" lam="$2"
  jq -nc --arg lam "$lam" '{last_assistant_message: $lam}' \
    | SESSION_LEDGER_TRANSCRIPT="$transcript" bash "$HOOK"
}

test_prefers_last_assistant_message_field_when_present() {
  # The real hook payload includes .last_assistant_message directly. It must
  # take priority over re-deriving from the transcript, since it is the
  # authoritative field and the transcript-derived path is only a fallback
  # for tests. Transcript text here deliberately has NO ledger, so a pass
  # here proves the field (which DOES have one) was actually used.
  local t out
  t="$SANDBOX/lam-priority.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"transcript text has no ledger at all"}]}}'
  out=$(run_with_lam "$t" "DONE: shipped it.\nNOT DONE: nothing.\nUNVERIFIED: nothing.")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_last_assistant_message_without_ledger_warns() {
  local t out
  t="$SANDBOX/lam-no-ledger.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"transcript text has no ledger at all"}]}}'
  out=$(run_with_lam "$t" "All wrapped up, nothing more to say.")
  assert_contains "$out" "session-closeout.md"
}

test_stop_hook_active_is_silent() {
  # Guards against the infinite-loop bug: when the harness re-fires the Stop
  # hook chain because a prior fire returned additionalContext, the
  # re-invocation's input sets stop_hook_active=true. The hook must bail out
  # immediately on that, even though the transcript would otherwise warn.
  local t out
  t="$SANDBOX/stop-hook-active.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"All finished, everything shipped."}]}}'
  out=$(printf '{"stop_hook_active":true}' | SESSION_LEDGER_TRANSCRIPT="$t" bash "$HOOK")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_unrelated_followup_after_taskcreate_is_silent() {
  # Turn-scoping: tracked work was already closed out, then a later,
  # unrelated user question got a plain text-only reply (no tool calls at
  # all in that turn). Requiring a fresh DONE marker on every trivial
  # follow-up for the rest of the session is the over-nagging this rule was
  # narrowed to avoid.
  local t out
  t="$SANDBOX/unrelated-followup.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DONE: shipped the PR."}]}}' \
    '{"type":"user","message":{"content":[{"type":"text","text":"unrelated question"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"sure, here is the answer"}]}}'
  out=$(run_with "$t")
  assert_empty "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')"
}

test_continued_work_after_taskcreate_without_closeout_still_warns() {
  # Turn-scoping must not become a blanket bypass: if the newest user turn
  # still does tool-based work (continuing the tracked task), the closeout
  # requirement on the last message still applies.
  local t out
  t="$SANDBOX/continued-work.jsonl"
  write_transcript "$t" \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DONE: shipped step one."}]}}' \
    '{"type":"user","message":{"content":[{"type":"text","text":"also do step two"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"Applied the edit."}]}}'
  out=$(run_with "$t")
  assert_contains "$out" "session-closeout.md"
}

run_test "no transcript path is silent" test_no_transcript_is_silent
run_test "no TaskCreate usage is silent" test_no_taskcreate_is_silent
run_test "TaskCreate without ledger warns" test_taskcreate_without_ledger_warns
run_test "TaskCreate with ledger is silent" test_taskcreate_with_ledger_is_silent
run_test "bare DONE without colon is silent" test_bare_done_without_colon_is_silent
run_test "markdown-bold **DONE** is silent" test_markdown_bold_done_is_silent
run_test "done mid-sentence still warns" test_done_mid_sentence_still_warns
run_test "ledger not on final line is still silent" test_ledger_not_on_final_line_is_still_silent
run_test "checks last message, not first" test_checks_last_message_not_first
run_test "prefers last_assistant_message field when present" test_prefers_last_assistant_message_field_when_present
run_test "last_assistant_message without ledger warns" test_last_assistant_message_without_ledger_warns
run_test "stop_hook_active re-fire is silent" test_stop_hook_active_is_silent
run_test "unrelated follow-up after closed-out TaskCreate is silent" test_unrelated_followup_after_taskcreate_is_silent
run_test "continued work without closeout still warns" test_continued_work_after_taskcreate_without_closeout_still_warns

print_summary

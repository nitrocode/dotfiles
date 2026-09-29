#!/bin/bash
# visibility: public
# Stop hook: for sessions that used TaskCreate (tracked multi-step work), check
# whether the final assistant message already contains a DONE / NOT DONE /
# UNVERIFIED-style closeout per $CLAUDE_CONFIG_DIR/rules/session-closeout.md and
# $CLAUDE_CONFIG_DIR/rules/task-tracking.md. If not, emit a non-blocking reminder to
# surface it before the session is treated as finished. Operationalizes a rule
# that already exists in prose but keeps getting skipped ("mostly achieved"
# outcomes per /insights, traced to dangling state left unverified).
#
# Stdin: hook JSON with .transcript_path and .last_assistant_message.
# Stdout: hookSpecificOutput with additionalContext when warranted, {} otherwise.
# Exit 0 always. Soft nudge only, never blocks.
#
# Heuristic only, deliberately cheap (no LLM call): a transcript that never
# used TaskCreate is assumed to be a simple/conversational session and is
# skipped entirely. A transcript path override is accepted via
# $SESSION_LEDGER_TRANSCRIPT for tests.
#
# The real hook payload includes .last_assistant_message directly (confirmed
# by capturing a live invocation), which is authoritative and used first.
# Deriving the last message by re-parsing the transcript file is only a
# fallback for the unit tests, which inject a synthetic transcript and have
# no .last_assistant_message to read. An earlier version of this hook always
# re-derived from the transcript via `jq -r ... | tail -n 1`, which is WRONG:
# jq -r expands embedded newlines in a .text string into real stdout lines,
# so a multi-paragraph reply becomes many lines and `tail -n 1` only grabs
# the trailing line, not the whole message. That silently missed ledger
# sections that were not on the very last line. Preferring the ready-made
# field avoids re-introducing that class of bug.
#
# stop_hook_active: when this hook's own additionalContext causes the
# harness to re-run the Stop hook chain instead of ending the turn, the
# re-invocation's input sets .stop_hook_active = true. An earlier version of
# this hook never checked that flag, so it nagged with the identical message
# every re-fire until the harness's hard cap (9 consecutive blocks) force-
# ended the turn. Bail out immediately on a re-fire instead.
#
# Turn-scoping: the original design nagged on every Stop for the rest of a
# session after a single TaskCreate use, even many turns later on purely
# conversational follow-ups unrelated to the tracked work. Narrowed so the
# requirement resets per user turn: if the most recent user message starts a
# turn where the assistant made no tool calls at all (pure Q&A, no continued
# work) and the last TaskCreate predates that user message, skip the nag.
# A turn that still does tool-based work (edits, commands, TaskUpdate, etc.)
# is unaffected and still must close out on its last message, same as before.

set -uo pipefail

INPUT=$(cat)

STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_HOOK_ACTIVE" = "true" ] && { echo '{}'; exit 0; }

TRANSCRIPT="${SESSION_LEDGER_TRANSCRIPT:-$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)}"

[ -z "$TRANSCRIPT" ] && { echo '{}'; exit 0; }
[ -f "$TRANSCRIPT" ] || { echo '{}'; exit 0; }

USED_TASK_CREATE=$(jq -r '
  select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name
' "$TRANSCRIPT" 2>/dev/null | grep -c '^TaskCreate$' || true)

[ "${USED_TASK_CREATE:-0}" -eq 0 ] && { echo '{}'; exit 0; }

# Turn-scoping check: does the most recent user turn look unrelated to the
# tracked work (no tool calls since the last user message), with the last
# TaskCreate having happened in an earlier turn? If so, skip regardless of
# closeout markers, this turn isn't the tracked work's wrap-up.
LAST_USER_IDX=$(jq -s '[to_entries[] | select(.value.type == "user")] | last.key // -1' "$TRANSCRIPT" 2>/dev/null)
LAST_USER_IDX=${LAST_USER_IDX:--1}

LAST_TC_IDX=$(jq -s '
  [to_entries[] | select(.value.type == "assistant" and ([.value.message.content[]? | select(.type == "tool_use" and .name == "TaskCreate")] | length > 0))]
  | last.key // -1
' "$TRANSCRIPT" 2>/dev/null)
LAST_TC_IDX=${LAST_TC_IDX:--1}

if [ "$LAST_USER_IDX" != "-1" ] && [ "${LAST_TC_IDX:--1}" -lt "$LAST_USER_IDX" ] 2>/dev/null; then
  CURRENT_TURN_HAS_TOOL_USE=$(jq -s --argjson lu "$LAST_USER_IDX" '
    any(to_entries[]; .key > $lu and .value.type == "assistant" and ([.value.message.content[]? | select(.type == "tool_use")] | length > 0))
  ' "$TRANSCRIPT" 2>/dev/null)
  [ "$CURRENT_TURN_HAS_TOOL_USE" = "false" ] && { echo '{}'; exit 0; }
fi

LAST_TEXT=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)

if [ -z "$LAST_TEXT" ]; then
  # Fallback for tests: slurp + build an array so `last` grabs one whole
  # text block as an atomic value (not just the trailing stdout line).
  LAST_TEXT=$(jq -rs '
    [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text] | last // ""
  ' "$TRANSCRIPT" 2>/dev/null)
fi

# Strip leading whitespace and markdown emphasis/heading characters before
# the anchored check, so "**DONE**: ..." (bold) or "# DONE ..." (heading)
# still counts as starting with DONE. Do NOT drop the anchor entirely: a
# bare unanchored `\bdone\b` would match "I think we are done here" mid-
# sentence in an otherwise-vague reply, see test_done_mid_sentence_still_warns.
STRIPPED_TEXT=$(printf '%s' "$LAST_TEXT" | sed -E 's/^[[:space:]*_#>`-]+//')

if printf '%s' "$LAST_TEXT" | grep -qiE 'not done|unverified' \
   || printf '%s' "$STRIPPED_TEXT" | grep -qiE '^done\b'; then
  echo '{}'
  exit 0
fi

MSG="This session used TaskCreate (tracked multi-step work) but the last message did not include a DONE / NOT DONE / UNVERIFIED closeout. Per session-closeout.md and task-tracking.md, re-verify any pending item (Jira transition, PR push, Slack draft, Confluence update) against live state before treating this as finished."

jq -n --arg msg "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: $msg
  }
}'

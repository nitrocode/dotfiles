#!/bin/bash
# visibility: public
# PostToolUse/Bash hook: notice when a command just failed with a generic
# "this flag/option doesn't exist" CLI error, and nudge toward adding a
# rule to bad-flag-rules.tsv (read by known-bad-flag-block.sh) instead of
# letting the same wrong flag get re-guessed in a future session.
#
# Detect-and-suggest only: this hook never writes bad-flag-rules.tsv
# itself. It surfaces a non-blocking systemMessage; a human still has to
# confirm the entry (via a normal Edit) before it becomes a live rule.
# That avoids a one-off typo, a missing-auth failure, or an
# environment-specific error getting permanently misclassified as "this
# flag doesn't exist."
#
# Stdin: hook JSON with .tool_input.command and .tool_response.content
#   (per https://code.claude.com/docs/en/hooks.md PostToolUse schema:
#   tool_response = {type: "text"|"error", content: "string"}).
# Stdout: {"systemMessage": "..."} at most once per (session, command
#   shape). Exit 0 always.

set -uo pipefail

STATE_DIR="${TMPDIR:-/tmp}/bad-flag-error-detect"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_response.content // empty' 2>/dev/null)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[ -z "$CMD" ] && exit 0
[ -z "$CONTENT" ] && exit 0
[ -z "$SESSION" ] && exit 0

# Generic "unknown/unrecognized/invalid/illegal option|flag" shapes across
# common CLI arg parsers (getopt, Go flag/cobra, Python argparse/click,
# Node yargs/commander), plus a couple of parser-specific phrasings.
ERROR_RE='(unknown|unrecognized|invalid|illegal)[[:space:]]+(option|flag|argument)|no such option|flag provided but not defined|not a valid option'

printf '%s' "$CONTENT" | grep -qiE -- "$ERROR_RE" || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

SHAPE=$(printf '%s' "$CMD" | tr -s '[:space:]' ' ' | head -c 120)
SHAPE_HASH=$(printf '%s' "$SHAPE" | shasum 2>/dev/null | cut -d' ' -f1)
[ -z "$SHAPE_HASH" ] && SHAPE_HASH=$(printf '%s' "$SHAPE" | cksum | cut -d' ' -f1)

WARNED_FILE="$STATE_DIR/${SESSION}.warned"
if [ -f "$WARNED_FILE" ] && grep -Fxq -- "$SHAPE_HASH" "$WARNED_FILE" 2>/dev/null; then
  exit 0
fi
printf '%s\n' "$SHAPE_HASH" >> "$WARNED_FILE"

# Best-effort extraction of the offending flag token, for a ready-to-edit
# suggestion. Falls back to a generic prompt if nothing is found.
FLAG=$(printf '%s' "$CONTENT" | grep -oE -- '--?[a-zA-Z][a-zA-Z0-9-]*' | tail -1)

MSG="Command failed with what looks like a nonexistent-flag error: '$(printf '%s' "$CMD" | head -c 80)'. If this flag genuinely doesn't exist (not an auth/env/cwd issue), consider proposing a rule for $CLAUDE_CONFIG_DIR/hooks/bad-flag-rules.tsv (tab-separated: <command regex>\\t<flag regex>\\t<message>)${FLAG:+, flag looked like '$FLAG'}. Confirm with the user before adding it, per editing-discipline.md."
jq -nc --arg m "$MSG" '{systemMessage: $m}'
exit 0

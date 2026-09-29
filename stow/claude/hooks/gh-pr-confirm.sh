#!/bin/bash
# visibility: public
# PreToolUse hook: confirm `gh pr create` via macOS modal before posting.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0
printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

TITLE=$(printf '%s' "$CMD" | grep -oE -- "--title[[:space:]]+[\"'][^\"']*[\"']" | head -1 | sed -E 's/--title[[:space:]]+["'\'']//; s/["'\''](\s|$)//' | head -c 200)

REASON="Post PR to GitHub"
[ -n "$TITLE" ] && REASON="${REASON} | Title: ${TITLE}"
REASON="${REASON}
Review title and body before posting."

printf '%s' "$INPUT" | exec bash "$CLAUDE_CONFIG_DIR/hooks/confirm-dialog.sh" '.+' "$REASON"

#!/bin/bash
# visibility: public
# PreToolUse hook: confirm `gh pr create` via macOS modal before posting.
# Also warns (does not block) if --title isn't Conventional Commits format,
# mirroring the same warn-only check in git-hooks/prepare-commit-msg so PR
# titles and commit subjects are held to the same convention.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0
printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' || exit 0

TITLE=$(printf '%s' "$CMD" | grep -oE -- "--title[[:space:]]+[\"'][^\"']*[\"']" | head -1 | sed -E 's/--title[[:space:]]+["'\'']//; s/["'\''](\s|$)//' | head -c 200)

REASON="Post PR to GitHub"
[ -n "$TITLE" ] && REASON="${REASON} | Title: ${TITLE}"

if [ -n "$TITLE" ]; then
  CC_REGEX='^(feat|fix|chore|docs|refactor|test|perf|style|build|ci|revert)(\([^)]+\))?!?: .+'
  if ! printf '%s' "$TITLE" | grep -qE "$CC_REGEX"; then
    REASON="${REASON}
WARNING: title does not match Conventional Commits (<type>(<scope>)?: <subject>)."
  fi
fi

REASON="${REASON}
Review title and body before posting."

printf '%s' "$INPUT" | exec bash "$CLAUDE_CONFIG_DIR/hooks/confirm-dialog.sh" '.+' "$REASON"

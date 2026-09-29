#!/bin/bash
# visibility: public
# PostToolUse hook: preserve exec bit on script files after Write/Edit.
# Insights flagged a session that lost the exec bit on a script.

set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')

if [[ -z "$FILE" || "$FILE" == "null" || ! -f "$FILE" ]]; then
  exit 0
fi

NEEDS_EXEC=0

case "$FILE" in
  *.sh|*.bash|*.zsh|*.py|*.rb|*.pl)
    NEEDS_EXEC=1
    ;;
esac

if [[ "$FILE" =~ /(bin|scripts|git-hooks|hooks)/[^/]+$ ]] && [[ ! "$FILE" =~ \.(md|txt|json|yaml|yml)$ ]]; then
  NEEDS_EXEC=1
fi

if [ "$NEEDS_EXEC" -eq 0 ]; then
  exit 0
fi

if head -c 2 "$FILE" 2>/dev/null | grep -q "^#!"; then
  if [ ! -x "$FILE" ]; then
    chmod +x "$FILE" 2>/dev/null || true
  fi
fi

exit 0

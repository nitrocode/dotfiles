#!/bin/bash
# visibility: public
# UserPromptSubmit hook: scan the user's prompt for colloquial keywords and inject
# a system-reminder hint pointing Claude at the relevant skill, subagent, or MCP.
# Catches prompts that don't match the skill's `description:` line directly.
#
# Stdin: hook JSON with .user_prompt
# Stdout: hookSpecificOutput with additionalContext if any rule matches.
# Exit 0 either way. Soft-suggestion, never blocks.
#
# Rules live in $CLAUDE_CONFIG_DIR/hooks/skill-suggest-rules.tsv (tab-separated):
#   <regex-pattern>\t<suggestion text>
# Empty lines and lines starting with # are ignored.

set -uo pipefail

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.user_prompt // .prompt // empty' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

RULES_FILE="$CLAUDE_CONFIG_DIR/hooks/skill-suggest-rules.tsv"
[ -f "$RULES_FILE" ] || exit 0

SUGGESTIONS=()
while IFS=$'\t' read -r pattern suggestion; do
  # Skip comments and blanks.
  case "$pattern" in ''|'#'*) continue;; esac
  [ -z "$suggestion" ] && continue
  if printf '%s' "$PROMPT" | grep -qiE "$pattern"; then
    SUGGESTIONS+=("$suggestion")
  fi
done < "$RULES_FILE"

[ "${#SUGGESTIONS[@]}" -eq 0 ] && exit 0

# Dedupe while preserving order.
SEEN=""
DEDUPED=()
for s in "${SUGGESTIONS[@]}"; do
  case "$SEEN" in
    *"|$s|"*) ;;
    *) DEDUPED+=("$s"); SEEN="$SEEN|$s|" ;;
  esac
done

BODY="Possibly relevant tools for this prompt (suggestion only, ignore if not applicable):"
for s in "${DEDUPED[@]}"; do
  BODY+=$'\n- '"$s"
done

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $body
  }
}'

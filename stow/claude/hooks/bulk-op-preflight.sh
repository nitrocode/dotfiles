#!/bin/bash
# visibility: public
# PreToolUse hook for Bash: detect bulk write patterns and remind about the dry-run rule
# from $CLAUDE_CONFIG_DIR/rules/bulk-operations.md.
#
# Stdin: hook JSON. Stdout: optional permissionDecision JSON with `ask` and a reason.
# Exit 0 either way; this is a soft reminder, not a hard block.
#
# Patterns matched (each implies a write loop >= threshold items):
#   - xargs with write-class commands (rm, mv, cp -r, aws ... delete/put, jira transition, gh issue close)
#   - GNU parallel with write-class commands
#   - shell for-loops over a list invoking write-class commands
#   - granted sso populate (known bulk command)
#   - jira-cli issue * (transition|close|delete) in a loop
#
# Skipped:
#   - read-only ops (list, describe, get, scan, search)
#   - explicit --dry-run / -n / --check flags present
#   - commands shorter than 40 chars (likely one-off)
#   - a for-loop over a LITERAL inline list (or brace expansion) with fewer
#     than THRESHOLD items -- e.g. `for k in ABC-1 ABC-2 ABC-3; do ...`.
#     Item count can only be known statically when the list is literal; a
#     list sourced from a command substitution ($(...), xargs, parallel)
#     has an unknown size and still triggers the reminder, matching the
#     "10+ items" language in rules/bulk-operations.md.

set -uo pipefail

THRESHOLD=10

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$CMD" ] && exit 0
[ "${#CMD}" -lt 40 ] && exit 0

# Skip if user explicitly opted into dry-run already.
if printf '%s' "$CMD" | grep -qE -- '(--dry-run|--check|--noop|--whatif|[[:space:]]-n[[:space:]])'; then
  exit 0
fi

# Try to statically count a literal for-loop list: `for x in a b c; do`.
# If the list contains command substitution ($(...) or backticks), its size
# is unknown and we deliberately leave ITEM_COUNT empty (still triggers).
ITEM_COUNT=""
INLINE_LIST=$(printf '%s' "$CMD" | grep -oE 'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+[^;]+' | sed -E 's/^for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+//' | head -n1)

if [ -n "$INLINE_LIST" ] && ! printf '%s' "$INLINE_LIST" | grep -qE '(\$\(|`)'; then
  if printf '%s' "$INLINE_LIST" | grep -qE '\{[0-9]+\.\.[0-9]+\}'; then
    # Numeric brace range: {START..END}
    START=$(printf '%s' "$INLINE_LIST" | grep -oE '\{[0-9]+\.\.[0-9]+\}' | head -n1 | grep -oE '^\{[0-9]+' | tr -d '{')
    END=$(printf '%s' "$INLINE_LIST" | grep -oE '\{[0-9]+\.\.[0-9]+\}' | head -n1 | grep -oE '[0-9]+\}$' | tr -d '}')
    ITEM_COUNT=$((END - START + 1))
  elif printf '%s' "$INLINE_LIST" | grep -qE '\{.*,.*\}'; then
    # Comma brace list: {a,b,c}
    BRACE_BODY=$(printf '%s' "$INLINE_LIST" | grep -oE '\{[^}]*,[^}]*\}' | head -n1 | tr -d '{}')
    ITEM_COUNT=$(( $(printf '%s' "$BRACE_BODY" | tr -cd ',' | wc -c) + 1 ))
  else
    # Plain whitespace-separated literal tokens.
    ITEM_COUNT=$(printf '%s\n' "$INLINE_LIST" | wc -w | tr -d ' ')
  fi
fi

if [ -n "$ITEM_COUNT" ] && [ "$ITEM_COUNT" -lt "$THRESHOLD" ] 2>/dev/null; then
  exit 0
fi

# Write-class verbs that indicate state mutation.
WRITE_VERBS='(rm|mv|cp[[:space:]]+-r|delete|destroy|terminate|put-|create-|update-|transition|close|merge|publish|send|apply|populate)'

# Bulk wrappers.
BULK_WRAPPERS='(xargs|parallel|for[[:space:]]+[a-zA-Z_]+[[:space:]]+in[[:space:]])'

REASON=""

# Pattern 1: bulk wrapper + write verb on the same line.
if printf '%s' "$CMD" | grep -qE "$BULK_WRAPPERS" && \
   printf '%s' "$CMD" | grep -qE "$WRITE_VERBS"; then
  REASON="Bulk wrapper (xargs/parallel/for-loop) with write verb detected."
fi

# Pattern 2: known bulk commands.
if [ -z "$REASON" ] && printf '%s' "$CMD" | grep -qE 'granted[[:space:]]+sso[[:space:]]+populate'; then
  REASON="granted sso populate is a known bulk operation."
fi

# Pattern 3: jira-cli bulk via while/for/xargs.
if [ -z "$REASON" ] && printf '%s' "$CMD" | grep -qE 'jira.*issue.*(transition|move|close|delete)' && \
   printf '%s' "$CMD" | grep -qE "$BULK_WRAPPERS"; then
  REASON="Jira bulk transition/close detected."
fi

# Pattern 4: gh issue/pr loop close.
if [ -z "$REASON" ] && printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+(issue|pr)[[:space:]]+(close|delete|merge)' && \
   printf '%s' "$CMD" | grep -qE "$BULK_WRAPPERS"; then
  REASON="gh issue/pr bulk close/merge detected."
fi

[ -z "$REASON" ] && exit 0

# Soft reminder: emit `ask` decision so the user sees the warning and approves.
jq -n --arg reason "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Bulk operation: " + $reason + " Per $CLAUDE_CONFIG_DIR/rules/bulk-operations.md, run on the first 2 items dry-run before the full batch. Approve only if dry-run already done.")
  }
}'

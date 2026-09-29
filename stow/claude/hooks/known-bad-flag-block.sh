#!/bin/bash
# visibility: public
# PreToolUse/Bash hook: block a command matching a known "this flag doesn't
# exist" rule before it runs, instead of letting the CLI itself error.
#
# Generalizes the original coderabbit-review-only hook: rules live in
# bad-flag-rules.tsv (tab-separated: command regex, flag regex, message) so
# adding a new command/flag pair is a data edit, not a new script. New
# candidate rules are proposed by bad-flag-error-detect.sh (PostToolUse)
# when it sees a real "unknown option" style failure; this hook never adds
# rules itself.
#
# Stdin: hook JSON with .tool_input.command
# Stdout: {"hookSpecificOutput": {"permissionDecision": "deny", ...}} on the
#   first matching rule; empty otherwise.
# Exit 0 always -- the deny is expressed through the JSON decision. Fails
# open if the rules file or jq is missing.

set -uo pipefail

RULES_FILE="$CLAUDE_CONFIG_DIR/hooks/bad-flag-rules.tsv"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$CMD" ] && exit 0
[ -f "$RULES_FILE" ] || exit 0

while IFS=$'\t' read -r cmd_re flag_re message; do
  [ -z "$cmd_re" ] && continue
  case "$cmd_re" in \#*) continue ;; esac
  [ -z "$flag_re" ] && continue

  if printf '%s' "$CMD" | grep -qE -- "$cmd_re" && printf '%s' "$CMD" | grep -qE -- "$flag_re"; then
    jq -n --arg msg "$message" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $msg
      }
    }'
    exit 0
  fi
done < "$RULES_FILE"

exit 0

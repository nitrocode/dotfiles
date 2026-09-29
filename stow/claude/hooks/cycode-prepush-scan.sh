#!/usr/bin/env bash
# visibility: public
# PreToolUse hook: before `git push` or `gh pr create`, scan working tree with Cycode.
# Blocks on Critical secret findings; warns and allows on High; allows otherwise.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$CMD" ]; then exit 0; fi

# Match push-class commands; skip the rest
if ! echo "$CMD" | grep -qE '(^|[;&|]\s*)(git\s+push|gh\s+pr\s+create)\b'; then
  exit 0
fi

if ! command -v cycode >/dev/null 2>&1; then exit 0; fi

# Need a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then exit 0; fi
REPO=$(git rev-parse --show-toplevel)

# Critical-threshold scan first; block on findings
CRIT_OUT=$(timeout 60 cycode --no-progress-meter --no-update-notifier scan --scan-type secret --severity-threshold critical path "$REPO" 2>&1)
CRIT_EXIT=$?

if [ "$CRIT_EXIT" -ne 0 ] && [ "$CRIT_EXIT" -ne 124 ]; then
  REASON=$(printf 'Cycode detected Critical secret finding(s) in %s. Resolve before push.\n\n%s' \
    "$REPO" "$(echo "$CRIT_OUT" | head -40)")
  jq -n --arg reason "$REASON" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
fi

# High-threshold scan; warn only
HIGH_OUT=$(timeout 60 cycode --no-progress-meter --no-update-notifier scan --scan-type secret --severity-threshold high path "$REPO" 2>&1)
HIGH_EXIT=$?

if [ "$HIGH_EXIT" -ne 0 ] && [ "$HIGH_EXIT" -ne 124 ]; then
  echo "WARNING: Cycode found High-severity secret finding(s) in $REPO. Push allowed; review:" >&2
  echo "$HIGH_OUT" | head -30 >&2
fi

exit 0

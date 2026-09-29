#!/bin/bash
# visibility: public
# PreToolUse hook: pop ONE macOS modal to approve a sensitive Bash command,
# matching against a table of (pattern, reason) pairs. Replaces N separate
# invocations of confirm-dialog.sh with a single process.
#
# Args: alternating --pattern <regex> --reason <text> pairs.
# Example:
#   bash confirm-dialog-multi.sh \
#     --pattern 'terraform[[:space:]]+(apply|destroy)' --reason 'Modifies or destroys Terraform-managed infrastructure' \
#     --pattern '(^|[;&|][[:space:]]*)kubectl[[:space:]]+delete' --reason 'Deletes Kubernetes resources'
#
# stdin: hook JSON. Outputs PreToolUse permissionDecision JSON if any pattern matches.
# Stops at the first matching pattern (no need to check the rest).

set -uo pipefail

PATTERNS=()
REASONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --pattern)
      shift
      PATTERNS+=("$1")
      shift
      ;;
    --reason)
      shift
      REASONS+=("$1")
      shift
      ;;
    *)
      echo "usage: $0 --pattern <regex> --reason <text> [--pattern <regex> --reason <text> ...]" >&2
      exit 2
      ;;
  esac
done

if [ "${#PATTERNS[@]}" -ne "${#REASONS[@]}" ] || [ "${#PATTERNS[@]}" -eq 0 ]; then
  echo "usage: $0 --pattern <regex> --reason <text> [...]" >&2
  exit 2
fi

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

MATCHED_REASON=""
for i in "${!PATTERNS[@]}"; do
  if printf '%s' "$CMD" | grep -qE "${PATTERNS[$i]}"; then
    MATCHED_REASON="${REASONS[$i]}"
    break
  fi
done

[ -z "$MATCHED_REASON" ] && exit 0

# "Allow for session" button: flag file keyed on session_id + the matched
# reason category + cwd + --profile (if present), so repeated matches of the
# same category IN THE SAME cwd/account (e.g. every "Destroys AWS resources"
# hit against the same --profile in a bulk loop) auto-allow for the rest of
# this session. Deliberately narrow: approving one account/stack must not
# silently cover the same category against a different account/stack.
# Not persisted beyond the session, not the permanent allowlist.
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "no-session"' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "no-cwd"' 2>/dev/null)
PROFILE=$(printf '%s' "$CMD" | grep -oE -- '--profile[[:space:]]+[^[:space:]]+' | head -1)
KEY_TEXT="${MATCHED_REASON}|cwd:${CWD}|${PROFILE}"
KEY_HASH=$(printf '%s' "$KEY_TEXT" | md5 -q 2>/dev/null || printf '%s' "$KEY_TEXT" | md5sum | cut -d' ' -f1)
ALLOW_DIR="/tmp/claude-dialog-session-allow"
ALLOW_FLAG="$ALLOW_DIR/${SESSION_ID}_${KEY_HASH}.flag"

OTEL_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/otel-trace.py"

emit_otel() {
  local decision="$1" gave_up="${2:-false}"
  printf '%s' "$INPUT" | jq --arg hook "confirm-dialog-multi.sh" --arg decision "$decision" \
    --arg category "$MATCHED_REASON" --argjson gave_up "$gave_up" \
    '. + {dialog_hook:$hook, dialog_decision:$decision, dialog_category:$category, dialog_gave_up:$gave_up}' \
    2>/dev/null | python3 "$OTEL_HOOK" DialogDecision >/dev/null 2>&1 &
}

if [ -f "$ALLOW_FLAG" ]; then
  emit_otel "session-allow-reuse"
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"Auto-allowed: session-scoped allow granted earlier this session for this category"}}'
  exit 0
fi

CMD_DISPLAY="$CMD"
if [ ${#CMD_DISPLAY} -gt 280 ]; then
  CMD_DISPLAY="${CMD_DISPLAY:0:180} … ${CMD_DISPLAY: -80}"
fi

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

TITLE="$(esc "Approve sensitive command?")"
BODY="$(esc "${MATCHED_REASON}

${CMD_DISPLAY}")"

GAVE_UP="false"
if [ -n "${CONFIRM_DIALOG_RESPONSE:-}" ]; then
  BUTTON="$CONFIRM_DIALOG_RESPONSE"
else
  osascript -e 'tell application "iTerm2" to activate' 2>/dev/null
  RESULT=$(osascript -e "tell application \"System Events\" to display dialog \"$BODY\" with title \"$TITLE\" buttons {\"Deny\", \"Allow for session\", \"Allow\"} default button \"Deny\" cancel button \"Deny\" with icon caution giving up after 240" 2>/dev/null)
  BUTTON=$(printf '%s' "$RESULT" | sed -nE 's/^button returned:([^,]+).*/\1/p')
  printf '%s' "$RESULT" | grep -q 'gave up:true' && GAVE_UP="true"
fi

if [ "$BUTTON" = "Allow for session" ]; then
  mkdir -p "$ALLOW_DIR"
  touch "$ALLOW_FLAG"
  emit_otel "session-allow-grant" "$GAVE_UP"
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"User approved via macOS dialog (allowed for rest of session)"}}'
elif [ "$BUTTON" = "Allow" ]; then
  emit_otel "allow" "$GAVE_UP"
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"User approved via macOS dialog"}}'
else
  emit_otel "deny" "$GAVE_UP"
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"User denied via macOS dialog"}}'
fi

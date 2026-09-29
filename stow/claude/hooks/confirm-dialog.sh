#!/bin/bash
# visibility: public
# PreToolUse hook: pop a macOS modal to approve a sensitive Bash command.
# Args:
#   $1 = regex pattern matched against .tool_input.command (POSIX ERE)
#   $2 = reason text shown in the dialog body
# stdin: hook JSON. Outputs PreToolUse permissionDecision JSON if pattern matches.
#
# "Allow for session" button: writes a flag file keyed on session_id + the
# reason's first line (its category) + cwd + --profile (if present), so
# repeated matches of the same category IN THE SAME cwd/account auto-allow
# for the rest of this session. Deliberately narrow: approving a dev-account
# rm/terraform/aws call must not silently cover the same category in a
# different cwd or a different --profile. Not persisted beyond the session,
# not the permanent allowlist.

set -uo pipefail

PATTERN="${1:?usage: $0 <regex-pattern> <reason>}"
REASON="${2:-Sensitive command requires approval}"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$CMD" ] && exit 0
printf '%s' "$CMD" | grep -qE "$PATTERN" || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "no-session"' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "no-cwd"' 2>/dev/null)
PROFILE=$(printf '%s' "$CMD" | grep -oE -- '--profile[[:space:]]+[^[:space:]]+' | head -1)
CATEGORY=$(printf '%s' "$REASON" | head -n1)
KEY_TEXT="${CATEGORY}|cwd:${CWD}|${PROFILE}"
KEY_HASH=$(printf '%s' "$KEY_TEXT" | md5 -q 2>/dev/null || printf '%s' "$KEY_TEXT" | md5sum | cut -d' ' -f1)
ALLOW_DIR="/tmp/claude-dialog-session-allow"
ALLOW_FLAG="$ALLOW_DIR/${SESSION_ID}_${KEY_HASH}.flag"

OTEL_HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/otel-trace.py"

emit_otel() {
  local decision="$1" gave_up="${2:-false}"
  printf '%s' "$INPUT" | jq --arg hook "confirm-dialog.sh" --arg decision "$decision" \
    --arg category "$CATEGORY" --argjson gave_up "$gave_up" \
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
BODY="$(esc "${REASON}

${CMD_DISPLAY}")"

GAVE_UP="false"
# Test mode: tests set CONFIRM_DIALOG_RESPONSE=Allow|Deny|"Allow for session" to skip the real modal.
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

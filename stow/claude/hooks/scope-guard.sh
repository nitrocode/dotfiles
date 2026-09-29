#!/bin/bash
# visibility: public
# PreToolUse hook (matcher: Edit|Write): tracks distinct files touched via
# Edit/Write this session and, once more than THRESHOLD distinct files have
# been touched, emits a one-time non-blocking reminder to state or confirm
# scope per $CLAUDE_CONFIG_DIR/rules/plan-mode.md and $CLAUDE_CONFIG_DIR/rules/editing-discipline.md
# (minimal-edit principle). This mechanically enforces a rule that already
# exists in prose but keeps getting skipped mid-session (wrong_approach and
# excessive_changes are the top friction categories per /insights).
#
# Stdin: hook JSON with .session_id, .tool_input.file_path
# Stdout: hookSpecificOutput with additionalContext, fired at most once per
# session (a .warned marker file suppresses repeats so it does not spam every
# edit past the threshold). Exit 0 always. Soft nudge only, never blocks.
#
# State dir: $SCOPE_GUARD_STATE_DIR, default /tmp/claude-scope-guard/
# (session-scoped, ephemeral by design, same convention as
# confirm-dialog-multi.sh's session-allow flags). Override the env var in
# tests to sandbox state instead of touching the real /tmp path.

set -uo pipefail

THRESHOLD=3
STATE_DIR="${SCOPE_GUARD_STATE_DIR:-/tmp/claude-scope-guard}"
mkdir -p "$STATE_DIR" 2>/dev/null

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[ -z "$FILE_PATH" ] && { echo '{}'; exit 0; }
[ -z "$SESSION_ID" ] && SESSION_ID="no-session"

FILES_STATE="$STATE_DIR/${SESSION_ID}.files"
WARNED_FLAG="$STATE_DIR/${SESSION_ID}.warned"

touch "$FILES_STATE" 2>/dev/null

# Dedupe: only append if this file has not been recorded yet this session.
if ! grep -qxF "$FILE_PATH" "$FILES_STATE" 2>/dev/null; then
  echo "$FILE_PATH" >> "$FILES_STATE"
fi

COUNT=$(grep -c . "$FILES_STATE" 2>/dev/null || echo 0)

# Already warned this session. Stay silent so it does not repeat on every
# subsequent edit past the threshold.
if [ -f "$WARNED_FLAG" ]; then
  echo '{}'
  exit 0
fi

if [ "$COUNT" -gt "$THRESHOLD" ]; then
  touch "$WARNED_FLAG" 2>/dev/null
  MSG="This session has now touched $COUNT distinct files via Edit or Write. If that crossed the 3+ file threshold without a stated plan or an explicit scope boundary, check plan-mode.md and editing-discipline.md before continuing. State the boundary now if it has not been said yet."
  jq -n --arg msg "$MSG" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $msg
    }
  }'
  exit 0
fi

echo '{}'
exit 0

#!/bin/bash
# visibility: public
# Stop hook: macOS notification when Claude finishes a response.
# stdin: hook JSON ({cwd, transcript_path, session_id, ...})
# Reads last user prompt from transcript and shows it alongside cwd + iTerm tab info.

set -uo pipefail

# Focus guard: skip notification when user is already looking at this iTerm pane.
FRONTMOST=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null)
if [ "$FRONTMOST" = "iTerm2" ] && [ -n "${ITERM_SESSION_ID:-}" ]; then
  CURRENT_SESSION_UUID=$(osascript -e 'tell application "iTerm2" to tell current window to tell current session to id' 2>/dev/null)
  MY_SESSION_UUID="${ITERM_SESSION_ID##*:}"
  if [ -n "$CURRENT_SESSION_UUID" ] && [ "$CURRENT_SESSION_UUID" = "$MY_SESSION_UUID" ]; then
    exit 0
  fi
fi

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

CWD_BASE=$(basename "${CWD:-?}")

LAST_PROMPT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  LAST_PROMPT=$(jq -r '
    select(.type == "user" and (.message.content | type) == "string")
    | .message.content
  ' "$TRANSCRIPT" 2>/dev/null \
    | tail -n 1 \
    | tr '\n' ' ' \
    | head -c 80)
fi

INFO=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "iTerm2"
    tell current window
        set tabList to tabs
        set currentTab to current tab
        set tabName to name of current session of currentTab
        repeat with i from 1 to count of tabList
            if item i of tabList is currentTab then
                return (i as text) & "," & tabName
            end if
        end repeat
    end tell
end tell
APPLESCRIPT
) || INFO=",unknown"

TAB_NUM=$(printf '%s' "$INFO" | cut -d, -f1)
TAB_NAME=$(printf '%s' "$INFO" | cut -d, -f2-)

TITLE="✅ Claude Done · ⌘${TAB_NUM}"
SUBTITLE="${CWD_BASE} · ${TAB_NAME}"
BODY="${LAST_PROMPT:-(no recent prompt)}"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

osascript -e "display notification \"$(esc "$BODY")\" with title \"$(esc "$TITLE")\" subtitle \"$(esc "$SUBTITLE")\""

#!/bin/bash
# visibility: public
# Notification hook: macOS alert when Claude needs your attention.
# Arg $1: subtype (permission_prompt | idle_prompt)
# stdin: hook JSON ({cwd, message, session_id, ...})

set -uo pipefail

SUBTYPE="${1:-attention}"
INPUT=$(cat)
MESSAGE=$(printf '%s' "$INPUT" | jq -r '.message // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
CWD_BASE=$(basename "${CWD:-?}")

TAB_NUM=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "iTerm2"
    tell current window
        set tabList to tabs
        set currentTab to current tab
        repeat with i from 1 to count of tabList
            if item i of tabList is currentTab then
                return i as text
            end if
        end repeat
    end tell
end tell
APPLESCRIPT
) || TAB_NUM="?"

case "$SUBTYPE" in
  permission_prompt)
    TITLE="🟡 Claude needs you · ⌘${TAB_NUM}"
    osascript -e 'tell application "iTerm2" to activate' 2>/dev/null
    ;;
  idle_prompt)
    TITLE="💭 Claude is idle · ⌘${TAB_NUM}"
    ;;
  *)
    TITLE="🔔 Claude · ⌘${TAB_NUM}"
    ;;
esac

SUBTITLE="${CWD_BASE}"
BODY="${MESSAGE:-(no detail)}"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

osascript -e "display notification \"$(esc "$BODY")\" with title \"$(esc "$TITLE")\" subtitle \"$(esc "$SUBTITLE")\""

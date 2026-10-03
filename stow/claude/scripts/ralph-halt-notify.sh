#!/usr/bin/env bash
# Polls a Ralph project's .ralph/status.json and fires a macOS notification
# (with sound) + spoken alert the moment status flips to "halted" - covers
# permission_denied halts, which ralph_loop.sh's own --notify flag does not
# cover (see .ralph/logs/ralph.log history for why).
#
# Usage: ralph-halt-notify.sh [PROJECT_DIR] [POLL_INTERVAL_SECS]
#   PROJECT_DIR         defaults to the current directory
#   POLL_INTERVAL_SECS  defaults to 15
#
# Run this in a separate terminal/pane alongside `ralph` / `ralph --monitor`.
# Exits cleanly on Ctrl-C. Notification failures never crash the watcher.
set -euo pipefail

PROJECT_DIR="${1:-.}"
POLL_INTERVAL_SECS="${2:-15}"
STATUS_FILE="$PROJECT_DIR/.ralph/status.json"

notify() {
    local reason="$1"
    osascript -e "display notification \"Ralph halted: ${reason}\" with title \"Ralph\" sound name \"Basso\"" 2>/dev/null || true
    say "Ralph halted" 2>/dev/null || true
}

if [[ ! -f "$STATUS_FILE" ]]; then
    echo "ralph-halt-notify: $STATUS_FILE not found yet, waiting for it to appear..." >&2
fi

last_status=""
while true; do
    if [[ -f "$STATUS_FILE" ]]; then
        current_status=$(jq -r '.status // ""' "$STATUS_FILE" 2>/dev/null || echo "")
        if [[ "$current_status" == "halted" && "$last_status" != "halted" ]]; then
            reason=$(jq -r '.exit_reason // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
            notify "$reason"
        fi
        last_status="$current_status"
    fi
    sleep "$POLL_INTERVAL_SECS"
done

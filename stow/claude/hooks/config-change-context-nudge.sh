#!/bin/bash
# visibility: public
# SessionStart hook: nudge to run /context when the config surface changed
# since the last session, instead of silently loading a stale mental model
# of what's active. Hashes settings.json + CLAUDE.md + the skills roster.
#
# Stdin: hook JSON (not used, hashing reads fixed paths directly)
# Stdout: {"systemMessage": "..."} if the hash changed (or no prior hash
#   exists). Always rewrites the stored hash. Exit 0 always, never blocks.

set -uo pipefail

STATE_DIR="$CLAUDE_CONFIG_DIR/state"
HASH_FILE="$STATE_DIR/config-hash.txt"
mkdir -p "$STATE_DIR" 2>/dev/null

SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
CLAUDE_MD="$CLAUDE_CONFIG_DIR/CLAUDE.md"

hash_input() {
  [ -f "$SETTINGS" ] && cat "$SETTINGS"
  [ -f "$CLAUDE_MD" ] && cat "$CLAUDE_MD"
  for f in $CLAUDE_CONFIG_DIR/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    grep -m1 '^description:' "$f" 2>/dev/null
  done | sort
}

NEW_HASH=$(hash_input | shasum -a 256 2>/dev/null | awk '{print $1}')

if [ -z "$NEW_HASH" ]; then
  exit 0
fi

OLD_HASH=""
[ -f "$HASH_FILE" ] && OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

printf '%s' "$NEW_HASH" > "$HASH_FILE"

if [ "$NEW_HASH" = "$OLD_HASH" ]; then
  exit 0
fi

BODY="Config changed since last session (settings.json, CLAUDE.md, or a skill roster). Run /context to audit what's loaded."

jq -n --arg body "$BODY" '{systemMessage: $body}'

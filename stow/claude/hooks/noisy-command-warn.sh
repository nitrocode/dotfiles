#!/bin/bash
# visibility: public
# PreToolUse/Bash hook: notice (never rewrite) a small set of known-noisy
# commands run without their quiet/output-limiting flag, and suggest it.
# Deliberately does not mutate the command (no updatedInput), auto-injecting
# flags risks silently changing semantics. See
# $CLAUDE_CONFIG_DIR/plans/session-hygiene-automation.md item 2 for the tradeoff.
#
# Stdin: hook JSON with .tool_input.command
# Stdout: {"systemMessage": "..."} if a noisy pattern is found without its
#   quiet flag. Exit 0 always, never blocks.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$CMD" ] && exit 0

SUGGESTIONS=()

if printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)npm[[:space:]]+(install|ci)([[:space:]]|$)'; then
  if ! printf '%s' "$CMD" | grep -qE '(--silent|-s)([[:space:]]|$)'; then
    SUGGESTIONS+=("npm install/ci without --silent/-s")
  fi
fi

if printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)git[[:space:]]+log([[:space:]]|$)'; then
  if ! printf '%s' "$CMD" | grep -qE '(--oneline|-n[[:space:]]*[0-9]|-[0-9]+)([[:space:]]|$)'; then
    SUGGESTIONS+=("git log without --oneline/-n/-1")
  fi
fi

if printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)docker[[:space:]]+build([[:space:]]|$)'; then
  if ! printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)-q([[:space:]]|$)'; then
    SUGGESTIONS+=("docker build without -q")
  fi
fi

if printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)kubectl[[:space:]]+get([[:space:]]|$)'; then
  if ! printf '%s' "$CMD" | grep -qE '(^|[;&|]|\s)-o([[:space:]]|$)'; then
    SUGGESTIONS+=("kubectl get without -o")
  fi
fi

[ "${#SUGGESTIONS[@]}" -eq 0 ] && exit 0

JOINED="${SUGGESTIONS[0]}"
for s in "${SUGGESTIONS[@]:1}"; do
  JOINED="$JOINED; $s"
done
BODY="Noisy command detected (${JOINED}). Consider the quiet/output-limiting flag to save context. See $CLAUDE_CONFIG_DIR/rules/cheatsheets.md."

jq -n --arg body "$BODY" '{systemMessage: $body}'

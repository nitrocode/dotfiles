#!/bin/bash
# visibility: public
# UserPromptSubmit hook: warn (never block) when the user submits /model or
# /effort mid-session. Switching either invalidates the prompt cache for the
# rest of the session (cost + latency hit), per token-efficiency.md session
# hygiene notes. First-turn switches are silent, there's no cache yet to bust.
#
# Stdin: hook JSON with .user_prompt (or .prompt) and .transcript_path
# Stdout: {"systemMessage": "..."} if warranted. Exit 0 always, fails open on
#   any missing/malformed transcript_path (no warning, no crash).

set -uo pipefail

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.user_prompt // .prompt // empty' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# Only /model or /effort, as the first token of the prompt.
if ! printf '%s' "$PROMPT" | grep -qE '^/(model|effort)([[:space:]]|$)'; then
  exit 0
fi

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# Fail open: no transcript path, or file doesn't exist/isn't readable.
[ -z "$TRANSCRIPT" ] && exit 0
[ -r "$TRANSCRIPT" ] || exit 0

# First turn = no prior user-role entries already in the transcript.
PRIOR_USER_TURNS=$(jq -sr '[.[] | select(.type == "user")] | length' "$TRANSCRIPT" 2>/dev/null)
[ -z "$PRIOR_USER_TURNS" ] && exit 0
[ "$PRIOR_USER_TURNS" -eq 0 ] 2>/dev/null && exit 0

BODY="Switching model/effort mid-session invalidates the prompt cache for the rest of this session (cost + latency hit). Fine if intentional, just flagging per session-hygiene notes."

jq -n --arg body "$BODY" '{systemMessage: $body}'

#!/bin/bash
# visibility: public
# PreToolUse/Bash hook: block a command whose text contains a live-looking
# secret (a GitHub PAT, AWS key, Okta token, etc.) before it runs -- catches
# the "echo $TOKEN" / "curl -H \"Authorization: Bearer $TOKEN\"" class of
# mistake at the source, since a materialized secret in a command string
# ends up echoed into tool output and the session transcript either way.
#
# Uses trufflehog's built-in detectors (`trufflehog stdin`) rather than a
# hand-rolled regex list -- trufflehog already knows hundreds of real
# credential shapes and is kept up to date upstream; --no-verification
# skips the live API call (this hook only needs "does this look like a
# real secret shape", not "is it currently valid" -- a revoked/rotated
# token in a command is still worth blocking, and calling out to the
# provider's API on every Bash command would be slow and noisy).
#
# Stdin: hook JSON with .tool_input.command
# Stdout: {"hookSpecificOutput": {"permissionDecision": "deny", ...}} if a
#   secret-shaped string is found; empty otherwise. Exit 0 always -- the
#   deny is expressed through the JSON decision, not a nonzero exit.
# Fails open (allows the command) if trufflehog isn't installed, or if
# jq/trufflehog themselves error -- this hook must never be the reason a
# legitimate command can't run.

set -uo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$CMD" ] && exit 0

command -v trufflehog >/dev/null 2>&1 || exit 0

FINDINGS=$(printf '%s' "$CMD" | trufflehog stdin --no-verification -j 2>/dev/null)

[ -z "$FINDINGS" ] && exit 0

DETECTOR=$(printf '%s' "$FINDINGS" | head -1 | jq -r '.DetectorName // "unknown"' 2>/dev/null)
[ -z "$DETECTOR" ] && DETECTOR="unknown"

jq -n --arg detector "$DETECTOR" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Blocked: command text matches a live-secret shape (detector: " + $detector + "). Never echo/print a credential value -- check presence only, e.g. `[ -n \"$VAR\" ] && echo set || echo unset`.")
  }
}'

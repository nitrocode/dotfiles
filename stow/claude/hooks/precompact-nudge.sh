#!/usr/bin/env bash
# PreCompact hook. Fire-and-forget: never blocks compaction, always exits 0.
# On a manual /compact trigger, reminds that /rewind is the cheaper option
# when recent turns are disposable (drops them instead of paying to
# summarize them), since PreCompact fires exactly when that choice is moot.
# No reminder on "auto" trigger (context-limit forced, no /rewind option).
#
# Input schema (stdin JSON): session_id, transcript_path, cwd, trigger
# ("manual" | "auto"), hook_event_name. Confirmed via
# https://code.claude.com/docs/en/hooks.md, PreCompact section.
#
# UNVERIFIED: whether plain stdout/stderr on exit 0 is actually surfaced to
# the user for this hook type (docs confirm stderr-on-block and
# systemMessage are shown; a fire-and-forget exit-0 path is less clear).
# Test live after wiring this in.
set -uo pipefail

input=$(cat)
trigger=$(printf '%s' "$input" | jq -r '.trigger // empty' 2>/dev/null || true)

if [ "$trigger" = "manual" ]; then
  echo "Compacting now. If the recent turns are junk rather than useful history, /rewind was the cheaper option (drops them instead of paying to summarize)." >&2
fi

exit 0

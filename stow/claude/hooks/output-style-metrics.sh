#!/usr/bin/env bash
# Stop hook. Fire-and-forget, never fails the turn (exit 0 always).
# Logs {timestamp, session_id, output_style, output_tokens, thinking_tokens,
# cwd} for the just-finished assistant turn to
# ~/.claude/logs/output-style-metrics.jsonl, for comparing token cost across
# output styles (e.g. Lean vs Concise) over time.
#
# Input schema (stdin JSON): session_id, transcript_path, cwd,
# hook_event_name. https://code.claude.com/docs/en/hooks.md
set -uo pipefail

input=$(cat)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

[ -z "$transcript_path" ] && exit 0
[ -f "$transcript_path" ] || exit 0

output_style=$(jq -r '.outputStyle // "default"' "$CLAUDE_CONFIG_DIR/settings.json" 2>/dev/null || echo "default")

LOG_DIR="$CLAUDE_CONFIG_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
LOG_FILE="$LOG_DIR/output-style-metrics.jsonl"

# Only scan the tail of the transcript (bounded cost on large files). The
# just-finished assistant message is at or near the end.
tail -c 200000 "$transcript_path" 2>/dev/null | python3 -c "
import json, sys

output_tokens = None
thinking_tokens = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get('type') != 'assistant':
        continue
    usage = (d.get('message') or {}).get('usage') or {}
    ot = usage.get('output_tokens')
    if ot is not None:
        output_tokens = ot
        thinking_tokens = (usage.get('output_tokens_details') or {}).get('thinking_tokens')

if output_tokens is None:
    sys.exit(1)
print(json.dumps({'output_tokens': output_tokens, 'thinking_tokens': thinking_tokens}))
" > /tmp/osm_usage_$$.json 2>/dev/null

if [ -s /tmp/osm_usage_$$.json ]; then
  usage_json=$(cat /tmp/osm_usage_$$.json)
  rm -f /tmp/osm_usage_$$.json
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$session_id" \
    --arg style "$output_style" \
    --arg cwd "$cwd" \
    --argjson usage "$usage_json" \
    '{timestamp: $ts, session_id: $sid, output_style: $style, cwd: $cwd} + $usage' \
    >> "$LOG_FILE" 2>/dev/null
else
  rm -f /tmp/osm_usage_$$.json
fi

exit 0

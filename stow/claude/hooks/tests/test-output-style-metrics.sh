#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/hooks/output-style-metrics.sh
set -u
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/hooks/output-style-metrics.sh"
echo "test-output-style-metrics.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/.claude/logs"
  ORIG_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
  export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
  printf '%s\n' '{"outputStyle":"Lean"}' > "$CLAUDE_CONFIG_DIR/settings.json"
  LOG_FILE="$CLAUDE_CONFIG_DIR/logs/output-style-metrics.jsonl"
  TRANSCRIPT="$SANDBOX/transcript.jsonl"
}

teardown_sandbox() {
  export CLAUDE_CONFIG_DIR="$ORIG_CLAUDE_CONFIG_DIR"
  rm -rf "$SANDBOX"
}

write_transcript_line() {
  local output_tokens="$1" thinking_tokens="${2:-0}"
  printf '{"type":"assistant","message":{"usage":{"output_tokens":%s,"output_tokens_details":{"thinking_tokens":%s}}}}\n' \
    "$output_tokens" "$thinking_tokens" >> "$TRANSCRIPT"
}

run_hook() {
  local input="$1"
  printf '%s' "$input" | bash "$SCRIPT"
}

test_logs_output_tokens_and_style() {
  setup_sandbox
  write_transcript_line 123 45
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\",\"cwd\":\"/tmp\"}"
  local line style tokens
  line=$(tail -1 "$LOG_FILE" 2>/dev/null)
  style=$(printf '%s' "$line" | jq -r '.output_style')
  tokens=$(printf '%s' "$line" | jq -r '.output_tokens')
  teardown_sandbox
  [ "$style" = "Lean" ] && [ "$tokens" = "123" ]
}

test_uses_last_assistant_entry_not_first() {
  setup_sandbox
  write_transcript_line 100
  write_transcript_line 200
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\",\"cwd\":\"/tmp\"}"
  local tokens
  tokens=$(tail -1 "$LOG_FILE" 2>/dev/null | jq -r '.output_tokens')
  teardown_sandbox
  [ "$tokens" = "200" ]
}

test_missing_transcript_path_exits_zero_no_log() {
  setup_sandbox
  run_hook '{"session_id":"s1"}'
  local rc=$?
  local logged=0
  [ -f "$LOG_FILE" ] && logged=1
  teardown_sandbox
  [ "$rc" -eq 0 ] && [ "$logged" -eq 0 ]
}

test_nonexistent_transcript_file_exits_zero_no_log() {
  setup_sandbox
  run_hook "{\"transcript_path\":\"$SANDBOX/does-not-exist.jsonl\",\"session_id\":\"s1\"}"
  local rc=$?
  local logged=0
  [ -f "$LOG_FILE" ] && logged=1
  teardown_sandbox
  [ "$rc" -eq 0 ] && [ "$logged" -eq 0 ]
}

test_transcript_with_no_assistant_entries_no_log() {
  setup_sandbox
  printf '{"type":"user","message":{}}\n' >> "$TRANSCRIPT"
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\"}"
  local logged=0
  [ -f "$LOG_FILE" ] && logged=1
  teardown_sandbox
  [ "$logged" -eq 0 ]
}

test_missing_output_style_defaults() {
  setup_sandbox
  printf '{}' > "$CLAUDE_CONFIG_DIR/settings.json"
  write_transcript_line 50
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\"}"
  local style
  style=$(tail -1 "$LOG_FILE" 2>/dev/null | jq -r '.output_style')
  teardown_sandbox
  [ "$style" = "default" ]
}

test_appends_not_overwrites() {
  setup_sandbox
  write_transcript_line 10
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\"}"
  write_transcript_line 20
  run_hook "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"s1\"}"
  local lines
  lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
  teardown_sandbox
  [ "$lines" = "2" ]
}

run_test "logs output tokens and active style"          test_logs_output_tokens_and_style
run_test "uses last assistant entry, not first"         test_uses_last_assistant_entry_not_first
run_test "missing transcript_path -> exit 0, no log"     test_missing_transcript_path_exits_zero_no_log
run_test "nonexistent transcript file -> exit 0, no log" test_nonexistent_transcript_file_exits_zero_no_log
run_test "no assistant entries -> no log"                test_transcript_with_no_assistant_entries_no_log
run_test "missing outputStyle defaults to 'default'"     test_missing_output_style_defaults
run_test "repeated runs append, don't overwrite"         test_appends_not_overwrites

print_summary

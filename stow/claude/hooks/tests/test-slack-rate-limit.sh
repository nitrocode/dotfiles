#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-slack-rate-limit.sh:"

HOOK="$CLAUDE_CONFIG_DIR/hooks/slack-rate-limit.sh"

# Sandbox HOME so the real $CLAUDE_CONFIG_DIR/state/slack-call-log.json is never touched.
SANDBOX=$(mktemp -d)
export HOME="$SANDBOX"
mkdir -p "$CLAUDE_CONFIG_DIR/state"

# Fast thresholds for the test run.
export SLACK_RATE_MIN_INTERVAL_S=1
export SLACK_RATE_MAX_CALLS=3
export SLACK_RATE_WINDOW_S=5

STATE_FILE="$CLAUDE_CONFIG_DIR/state/slack-call-log.json"

reset_state() {
  rm -f "$STATE_FILE"
  rmdir "$CLAUDE_CONFIG_DIR/state/slack-call-log.lock" 2>/dev/null || true
}

run_bash() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
  printf '%s' "$input" | bash "$HOOK"
}

run_mcp() {
  local tool="$1"
  local input
  input=$(jq -nc --arg t "$tool" '{tool_name:$t,tool_input:{}}')
  printf '%s' "$input" | bash "$HOOK"
}

elapsed_ms() {
  # Wall-clock elapsed time in ms while running "$@".
  local start end
  start=$(date +%s%N)
  "$@" >/dev/null 2>&1
  end=$(date +%s%N)
  echo $(( (end - start) / 1000000 ))
}

test_non_matching_bash_no_delay() {
  reset_state
  local ms
  ms=$(elapsed_ms run_bash "ls -la")
  [[ ! -f "$STATE_FILE" ]] && (( ms < 500 ))
}

test_first_slackcli_call_no_delay_writes_state() {
  reset_state
  local ms
  ms=$(elapsed_ms run_bash "slackcli messages send --channel foo --text hi")
  local count
  count=$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)
  (( ms < 500 )) && [[ "$count" == "1" ]]
}

test_second_call_within_min_interval_sleeps() {
  reset_state
  run_bash "slackcli read" >/dev/null 2>&1
  local ms
  ms=$(elapsed_ms run_bash "agent-slack read foo")
  # Expect a sleep close to SLACK_RATE_MIN_INTERVAL_S (1s = 1000ms).
  (( ms >= 700 && ms <= 3000 ))
}

test_call_at_cap_sleeps_until_slot_frees() {
  reset_state
  export SLACK_RATE_MIN_INTERVAL_S=0
  # Fill to cap (3 calls), spaced enough to avoid min-interval waits.
  for _ in 1 2 3; do
    run_bash "slackcli read" >/dev/null 2>&1
    sleep 1.2
  done
  local ms
  ms=$(elapsed_ms run_bash "slackcli read")
  export SLACK_RATE_MIN_INTERVAL_S=1
  # Oldest of the 3 ages out at ~5s from its own timestamp; some wait expected,
  # but well under the full window since 2 calls have already elapsed.
  (( ms >= 500 ))
}

test_mcp_tool_treated_like_matching_bash() {
  reset_state
  local ms
  ms=$(elapsed_ms run_mcp "mcp__claude_ai_Slack__slack_read_channel")
  local count
  count=$(jq 'length' "$STATE_FILE" 2>/dev/null || echo 0)
  (( ms < 500 )) && [[ "$count" == "1" ]]
}

test_state_prunes_old_timestamps() {
  reset_state
  export SLACK_RATE_MIN_INTERVAL_S=0
  run_bash "slackcli read" >/dev/null 2>&1
  sleep 6  # exceeds SLACK_RATE_WINDOW_S=5, so the first entry ages out
  run_bash "slackcli read" >/dev/null 2>&1
  export SLACK_RATE_MIN_INTERVAL_S=1
  local count
  count=$(jq 'length' "$STATE_FILE")
  [[ "$count" == "1" ]]
}

test_lock_contention_produces_two_clean_entries() {
  reset_state
  export SLACK_RATE_MIN_INTERVAL_S=0
  run_bash "slackcli read" >/dev/null 2>&1 &
  local p1=$!
  run_bash "slackcli read" >/dev/null 2>&1 &
  local p2=$!
  wait "$p1" "$p2"
  export SLACK_RATE_MIN_INTERVAL_S=1
  local count
  count=$(jq 'length' "$STATE_FILE" 2>/dev/null || echo "invalid")
  [[ "$count" == "2" ]]
}

run_test "non-matching Bash command -> no delay, no state" test_non_matching_bash_no_delay
run_test "first slackcli call -> no delay, state created" test_first_slackcli_call_no_delay_writes_state
run_test "second call within min interval -> sleeps" test_second_call_within_min_interval_sleeps
run_test "call at cap -> sleeps until slot frees" test_call_at_cap_sleeps_until_slot_frees
run_test "mcp Slack tool -> treated like matching Bash" test_mcp_tool_treated_like_matching_bash
run_test "state prunes timestamps outside window" test_state_prunes_old_timestamps
run_test "lock contention -> two well-formed entries" test_lock_contention_produces_two_clean_entries

rm -rf "$SANDBOX"

print_summary

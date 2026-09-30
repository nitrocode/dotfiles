#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/hooks/precompact-nudge.sh
set -u
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/hooks/precompact-nudge.sh"
echo "test-precompact-nudge.sh:"

run_script() {
  printf '%s' "$1" | bash "$SCRIPT"
}

test_manual_trigger_prints_rewind_reminder() {
  local err
  err=$(run_script '{"trigger":"manual"}' 2>&1 1>/dev/null)
  assert_contains "$err" "/rewind"
}

test_manual_trigger_exits_zero() {
  run_script '{"trigger":"manual"}' >/dev/null 2>&1
  [ $? -eq 0 ]
}

test_auto_trigger_no_output() {
  local err
  err=$(run_script '{"trigger":"auto"}' 2>&1 1>/dev/null)
  assert_empty "$err"
}

test_auto_trigger_exits_zero() {
  run_script '{"trigger":"auto"}' >/dev/null 2>&1
  [ $? -eq 0 ]
}

test_missing_trigger_no_output() {
  local err
  err=$(run_script '{}' 2>&1 1>/dev/null)
  assert_empty "$err"
}

test_malformed_json_exits_zero_no_crash() {
  local out
  out=$(printf 'not json' | bash "$SCRIPT" 2>&1)
  local rc=$?
  [ "$rc" -eq 0 ]
}

run_test "manual trigger prints /rewind reminder"      test_manual_trigger_prints_rewind_reminder
run_test "manual trigger exits 0"                       test_manual_trigger_exits_zero
run_test "auto trigger produces no output"              test_auto_trigger_no_output
run_test "auto trigger exits 0"                         test_auto_trigger_exits_zero
run_test "missing trigger field produces no output"     test_missing_trigger_no_output
run_test "malformed json exits 0, no crash"              test_malformed_json_exits_zero_no_crash

print_summary

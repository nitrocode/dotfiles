#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-wakeup-count-warn.sh:"

HOOK="$HOOKS_DIR/wakeup-count-warn.sh"
STATE_ROOT="${TMPDIR:-/tmp}/wakeup-count-warn"

new_session() {
  printf 'test-%s-%s' "$RANDOM" "$RANDOM"
}

cleanup_session() {
  rm -f "$STATE_ROOT/$1.count" "$STATE_ROOT/$1.last_warned" 2>/dev/null
}

run_with() {
  local session="$1"
  local input
  input=$(jq -nc --arg s "$session" '{session_id:$s}')
  printf '%s' "$input" | bash "$HOOK"
}

run_n_times() {
  local session="$1" n="$2"
  local i=0 out=""
  while [ "$i" -lt "$n" ]; do
    out=$(run_with "$session")
    i=$((i + 1))
  done
  printf '%s' "$out"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"ScheduleWakeup wakeups"*) return 0;;
    *)
      printf '    expected a wakeup-count warning, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_under_threshold_silent() {
  local s; s=$(new_session)
  local out; out=$(run_n_times "$s" 5)
  cleanup_session "$s"
  assert_empty "$out"
}

test_at_threshold_warns() {
  local s; s=$(new_session)
  local out; out=$(run_n_times "$s" 8)
  cleanup_session "$s"
  assert_warns "$out"
}

test_same_multiple_twice_silent_second_time() {
  local s; s=$(new_session)
  run_n_times "$s" 8 >/dev/null
  local out; out=$(run_with "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_next_multiple_warns_again() {
  local s; s=$(new_session)
  run_n_times "$s" 16
  local out; out=$(run_with "$s")
  cleanup_session "$s"
  # 17th call is still within multiple 2 (16/8=2), already warned at 16th; not yet 24.
  assert_empty "$out"
}

test_reaches_second_threshold_warns() {
  local s; s=$(new_session)
  local out; out=$(run_n_times "$s" 16)
  cleanup_session "$s"
  assert_warns "$out"
}

test_missing_session_id_fails_open() {
  local out
  out=$(printf '%s' '{}' | bash "$HOOK")
  assert_empty "$out"
}

test_counts_are_independent_per_session() {
  local s1; s1=$(new_session)
  local s2; s2=$(new_session)
  run_n_times "$s1" 8 >/dev/null
  local out; out=$(run_with "$s2")
  cleanup_session "$s1"
  cleanup_session "$s2"
  assert_empty "$out"
}

run_test "under threshold -> silent" test_under_threshold_silent
run_test "at threshold (8) -> warns" test_at_threshold_warns
run_test "same multiple twice -> silent 2nd time" test_same_multiple_twice_silent_second_time
run_test "9th-16th calls -> silent until next multiple" test_next_multiple_warns_again
run_test "reaches 2nd threshold (16) -> warns again" test_reaches_second_threshold_warns
run_test "missing session_id -> fails open" test_missing_session_id_fails_open
run_test "counts independent per session" test_counts_are_independent_per_session

print_summary

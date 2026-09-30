#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-session-length-warn.sh:"

HOOK="$HOOKS_DIR/session-length-warn.sh"
STATE_ROOT="${TMPDIR:-/tmp}/session-length-warn"
TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

new_session() {
  printf 'test-%s-%s' "$RANDOM" "$RANDOM"
}

cleanup_session() {
  rm -f "$STATE_ROOT/$1.last_warned" 2>/dev/null
}

make_transcript() {
  # $1 = number of assistant-type turns to write
  local n="$1" f="$TMPDIR_T/transcript-$RANDOM.jsonl"
  : > "$f"
  local i=0
  while [ "$i" -lt "$n" ]; do
    echo '{"type":"assistant","role":"assistant"}' >> "$f"
    i=$((i + 1))
  done
  echo "$f"
}

run_with() {
  local transcript="$1" session="$2"
  local input
  input=$(jq -nc --arg t "$transcript" --arg s "$session" '{transcript_path:$t,session_id:$s}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"turns"*) return 0;;
    *)
      printf '    expected a turn-count warning, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_under_threshold_silent() {
  local s; s=$(new_session)
  local t; t=$(make_transcript 100)
  local out; out=$(run_with "$t" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_over_threshold_warns() {
  local s; s=$(new_session)
  local t; t=$(make_transcript 350)
  local out; out=$(run_with "$t" "$s")
  cleanup_session "$s"
  assert_warns "$out"
}

test_same_threshold_twice_silent_second_time() {
  local s; s=$(new_session)
  local t; t=$(make_transcript 350)
  run_with "$t" "$s" >/dev/null
  local out; out=$(run_with "$t" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_next_threshold_warns_again() {
  local s; s=$(new_session)
  local t1; t1=$(make_transcript 350)
  run_with "$t1" "$s" >/dev/null
  local t2; t2=$(make_transcript 650)
  local out; out=$(run_with "$t2" "$s")
  cleanup_session "$s"
  assert_warns "$out"
}

test_missing_transcript_path_fails_open() {
  local input='{"session_id":"test-missing-transcript"}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_malformed_transcript_path_fails_open() {
  local s; s=$(new_session)
  local out; out=$(run_with "/nonexistent/path/does-not-exist.jsonl" "$s")
  cleanup_session "$s"
  assert_empty "$out"
}

test_missing_session_id_fails_open() {
  local t; t=$(make_transcript 350)
  local input
  input=$(jq -nc --arg t "$t" '{transcript_path:$t}')
  local out; out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

run_test "under threshold -> silent" test_under_threshold_silent
run_test "over threshold -> warns" test_over_threshold_warns
run_test "same threshold twice -> silent 2nd time" test_same_threshold_twice_silent_second_time
run_test "next threshold -> warns again" test_next_threshold_warns_again
run_test "missing transcript_path -> fails open" test_missing_transcript_path_fails_open
run_test "malformed transcript_path -> fails open" test_malformed_transcript_path_fails_open
run_test "missing session_id -> fails open" test_missing_session_id_fails_open

print_summary

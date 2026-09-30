#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-model-effort-switch-warn.sh:"

HOOK="$HOOKS_DIR/model-effort-switch-warn.sh"
TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

make_transcript() {
  # $1 = number of prior user-type lines to write
  local n="$1" f="$TMPDIR_T/transcript-$RANDOM.jsonl"
  : > "$f"
  local i=0
  while [ "$i" -lt "$n" ]; do
    echo '{"type":"user","role":"user"}' >> "$f"
    i=$((i + 1))
  done
  echo "$f"
}

run_with() {
  local prompt="$1" transcript="$2"
  local input
  input=$(jq -nc --arg p "$prompt" --arg t "$transcript" '{user_prompt:$p,transcript_path:$t,session_id:"test"}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"prompt cache"*) return 0;;
    *)
      printf '    expected a cache-invalidation warning, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_first_turn_model_silent() {
  local t; t=$(make_transcript 0)
  local out; out=$(run_with '/model opus' "$t")
  assert_empty "$out"
}

test_later_turn_model_warns() {
  local t; t=$(make_transcript 1)
  local out; out=$(run_with '/model opus' "$t")
  assert_warns "$out"
}

test_later_turn_effort_warns() {
  local t; t=$(make_transcript 2)
  local out; out=$(run_with '/effort high' "$t")
  assert_warns "$out"
}

test_unrelated_prompt_silent() {
  local t; t=$(make_transcript 3)
  local out; out=$(run_with 'please review this diff' "$t")
  assert_empty "$out"
}

test_missing_transcript_path_fails_open() {
  local input='{"user_prompt":"/model opus"}'
  local out
  out=$(printf '%s' "$input" | bash "$HOOK")
  assert_empty "$out"
}

test_malformed_transcript_path_fails_open() {
  local out; out=$(run_with '/model opus' "/nonexistent/path/does-not-exist.jsonl")
  assert_empty "$out"
}

test_empty_prompt_silent() {
  local out
  out=$(printf '%s' '{"user_prompt":""}' | bash "$HOOK")
  assert_empty "$out"
}

run_test "first-turn /model -> silent" test_first_turn_model_silent
run_test "later-turn /model -> warns" test_later_turn_model_warns
run_test "later-turn /effort -> warns" test_later_turn_effort_warns
run_test "unrelated prompt -> silent" test_unrelated_prompt_silent
run_test "missing transcript_path -> fails open" test_missing_transcript_path_fails_open
run_test "malformed transcript_path -> fails open" test_malformed_transcript_path_fails_open
run_test "empty prompt -> silent" test_empty_prompt_silent

print_summary

#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-confirm-dialog.sh:"

PATTERN='terraform[[:space:]]+(apply|destroy)'

test_match_allow() {
  local input='{"tool_input":{"command":"terraform apply"},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_decision "$out" "allow"
}

test_match_deny() {
  local input='{"tool_input":{"command":"terraform destroy"},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Deny bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_decision "$out" "deny"
}

test_match_no_response_denies() {
  # If env var unset and we somehow had no button, defaults to deny.
  # We can't easily test this without invoking osascript. Skip the live path; test the empty BUTTON branch
  # by setting CONFIRM_DIALOG_RESPONSE to literal empty (treated as unset). Hack: use a non-Allow value.
  local input='{"tool_input":{"command":"terraform apply"},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=unknown bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_decision "$out" "deny"
}

test_no_match_silent() {
  local input='{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_empty "$out"
}

test_empty_command_silent() {
  local input='{"tool_input":{},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_empty "$out"
}

test_atmos_terraform_apply_matches() {
  # Important: user explicitly asked for atmos terraform apply to be gated.
  local input='{"tool_input":{"command":"atmos terraform apply -stack prod"},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_decision "$out" "allow"
}

test_long_command_works() {
  local long_args
  long_args=$(printf 'arg%s ' {1..200})
  local input
  input=$(jq -nc --arg cmd "terraform apply $long_args" '{tool_input:{command:$cmd},cwd:"/tmp"}')
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason')
  assert_decision "$out" "allow"
}

session_allow_key_hash() {
  # Mirrors confirm-dialog.sh's KEY_TEXT="${CATEGORY}|cwd:${CWD}|${PROFILE}" formula.
  local category="$1" cwd="$2" profile="${3:-}"
  local key_text="${category}|cwd:${cwd}|${profile}"
  printf '%s' "$key_text" | md5 -q 2>/dev/null || printf '%s' "$key_text" | md5sum | cut -d' ' -f1
}

test_allow_for_session_persists() {
  local sid="test-session-allow-single-$$"
  local key_hash flag_dir flag_file
  key_hash=$(session_allow_key_hash 'test reason for session' '/tmp')
  flag_dir="/tmp/claude-dialog-session-allow"
  flag_file="${flag_dir}/${sid}_${key_hash}.flag"
  rm -f "$flag_file"

  local input1
  input1=$(jq -nc --arg sid "$sid" '{tool_input:{command:"terraform apply"},cwd:"/tmp",session_id:$sid}')
  local out1
  out1=$(printf '%s' "$input1" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason for session')

  if ! assert_decision "$out1" "allow"; then rm -f "$flag_file"; return 1; fi
  if [ ! -f "$flag_file" ]; then
    printf '    expected session-allow flag file at %s\n' "$flag_file" >&2
    return 1
  fi

  # Second call, same session + same reason category, no response override needed:
  # the flag should short-circuit straight to allow without touching osascript.
  local input2
  input2=$(jq -nc --arg sid "$sid" '{tool_input:{command:"terraform destroy"},cwd:"/tmp",session_id:$sid}')
  local out2
  out2=$(printf '%s' "$input2" | bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'test reason for session')

  rm -f "$flag_file"
  assert_decision "$out2" "allow"
}

test_allow_for_session_scoped_to_session_id() {
  # Same reason category, different session_id: the flag from one session must not leak into another.
  local sid_a="test-session-allow-a-$$"
  local sid_b="test-session-allow-b-$$"
  local key_hash flag_dir
  key_hash=$(session_allow_key_hash 'scoped test reason' '/tmp')
  flag_dir="/tmp/claude-dialog-session-allow"
  rm -f "${flag_dir}/${sid_a}_${key_hash}.flag" "${flag_dir}/${sid_b}_${key_hash}.flag"

  local input_a
  input_a=$(jq -nc --arg sid "$sid_a" '{tool_input:{command:"terraform apply"},cwd:"/tmp",session_id:$sid}')
  printf '%s' "$input_a" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'scoped test reason' > /dev/null

  local input_b
  input_b=$(jq -nc --arg sid "$sid_b" '{tool_input:{command:"terraform apply"},cwd:"/tmp",session_id:$sid}')
  local out_b
  out_b=$(printf '%s' "$input_b" | CONFIRM_DIALOG_RESPONSE=Deny bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'scoped test reason')

  rm -f "${flag_dir}/${sid_a}_${key_hash}.flag" "${flag_dir}/${sid_b}_${key_hash}.flag"
  assert_decision "$out_b" "deny"
}

test_allow_for_session_scoped_to_cwd() {
  # Same session_id, same reason category, different cwd (different repo/account):
  # approving in cwd A must not auto-allow the same category in cwd B.
  local sid="test-session-allow-cwd-$$"
  local hash_a hash_b flag_dir
  hash_a=$(session_allow_key_hash 'cwd scoped reason' '/tmp/repo-a')
  hash_b=$(session_allow_key_hash 'cwd scoped reason' '/tmp/repo-b')
  flag_dir="/tmp/claude-dialog-session-allow"
  rm -f "${flag_dir}/${sid}_${hash_a}.flag" "${flag_dir}/${sid}_${hash_b}.flag"

  local input_a
  input_a=$(jq -nc --arg sid "$sid" '{tool_input:{command:"terraform apply"},cwd:"/tmp/repo-a",session_id:$sid}')
  printf '%s' "$input_a" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'cwd scoped reason' > /dev/null

  local input_b
  input_b=$(jq -nc --arg sid "$sid" '{tool_input:{command:"terraform apply"},cwd:"/tmp/repo-b",session_id:$sid}')
  local out_b
  out_b=$(printf '%s' "$input_b" | CONFIRM_DIALOG_RESPONSE=Deny bash "$HOOKS_DIR/confirm-dialog.sh" "$PATTERN" 'cwd scoped reason')

  rm -f "${flag_dir}/${sid}_${hash_a}.flag" "${flag_dir}/${sid}_${hash_b}.flag"
  assert_decision "$out_b" "deny"
}

run_test "matches pattern -> allow when mocked Allow" test_match_allow
run_test "matches pattern -> deny when mocked Deny" test_match_deny
run_test "unknown response defaults to deny (fail closed)" test_match_no_response_denies
run_test "no pattern match -> silent (exit 0, no output)" test_no_match_silent
run_test "empty command -> silent" test_empty_command_silent
run_test "atmos terraform apply matches the same regex" test_atmos_terraform_apply_matches
run_test "long command (truncated for dialog) still emits decision" test_long_command_works
run_test "Allow for session -> allow + persists for next match, same session" test_allow_for_session_persists
run_test "Allow for session -> does not leak across different session_id" test_allow_for_session_scoped_to_session_id
run_test "Allow for session -> does not leak across different cwd" test_allow_for_session_scoped_to_cwd

print_summary

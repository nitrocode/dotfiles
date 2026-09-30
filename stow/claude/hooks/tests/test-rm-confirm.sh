#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-rm-confirm.sh:"

# Use a real cwd that exists so awk/perl resolution doesn't error.
TEST_CWD="$CLAUDE_CONFIG_DIR/hooks"

run_rm() {
  # $1 = command, $2 = expected CONFIRM_DIALOG_RESPONSE (only used if dialog branch hit)
  local cmd="$1" mock="${2:-Allow}"
  local input
  input=$(jq -nc --arg cmd "$cmd" --arg cwd "$TEST_CWD" '{tool_input:{command:$cmd},cwd:$cwd}')
  printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE="$mock" bash "$HOOKS_DIR/rm-confirm.sh"
}

test_no_rm() {
  local out; out=$(run_rm "ls -la")
  assert_empty "$out"
}

test_rm_without_r_flag() {
  # rm without -r is not gated by this script
  local out; out=$(run_rm "rm somefile")
  assert_empty "$out"
}

test_rm_r_inside_cwd_relative() {
  local out; out=$(run_rm "rm -rf ./build")
  assert_empty "$out"
}

test_rm_r_inside_cwd_absolute() {
  local out; out=$(run_rm "rm -rf $TEST_CWD/build")
  assert_empty "$out"
}

test_rm_r_inside_home() {
  local out; out=$(run_rm "rm -rf $HOME/some-temp-dir")
  assert_empty "$out"
}

test_rm_r_home_tilde() {
  # ~/.cache is a shared cache (pre-commit, pip, brew, gh, etc.) -> dialog, not silent.
  local out; out=$(run_rm "rm -rf ~/.cache/foo" "Allow")
  assert_decision "$out" "allow"
}

test_rm_r_shared_cache_deny() {
  local out; out=$(run_rm "rm -rf ~/.cache/pre-commit" "Deny")
  assert_decision "$out" "deny"
}

test_rm_r_npm_cache_dialog() {
  local out; out=$(run_rm "rm -rf ~/.npm" "Deny")
  assert_decision "$out" "deny"
}

test_rm_r_macos_caches_dialog() {
  local out; out=$(run_rm "rm -rf ~/Library/Caches/Homebrew" "Deny")
  assert_decision "$out" "deny"
}

test_rm_r_home_nonshared_silent() {
  # A non-cache dir inside HOME stays silent.
  local out; out=$(run_rm "rm -rf $HOME/some-temp-dir-not-cache")
  assert_empty "$out"
}

test_rm_r_outside_both_pops_dialog() {
  # /tmp is outside cwd and outside home -> dialog. Mock=Allow -> permissionDecision=allow.
  local out; out=$(run_rm "rm -rf /tmp/notmine" "Allow")
  assert_decision "$out" "allow"
}

test_rm_r_outside_both_deny() {
  local out; out=$(run_rm "rm -rf /tmp/notmine" "Deny")
  assert_decision "$out" "deny"
}

test_rm_r_catastrophic_root() {
  # /etc is catastrophic -> hard deny, no dialog (mock irrelevant).
  local out; out=$(run_rm "rm -rf /etc/foo" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_catastrophic_root_path() {
  local out; out=$(run_rm "rm -rf /" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_catastrophic_usr() {
  local out; out=$(run_rm "rm -rf /usr/local/bin/foo" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_catastrophic_private_etc() {
  # Direct /private/etc/... path (post-canonicalization form on macOS).
  local out; out=$(run_rm "rm -rf /private/etc/something" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_recursive_long_flag() {
  # --recursive variant also gated
  local out; out=$(run_rm "rm --recursive /etc/foo" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_multiple_paths_one_catastrophic() {
  # If ANY path is catastrophic, deny wins
  local out; out=$(run_rm "rm -rf ./build /etc/foo" "Allow")
  assert_decision "$out" "deny"
}

test_rm_r_multiple_paths_one_dangerous() {
  # Inside path + outside-both path = dialog (allow with mock)
  local out; out=$(run_rm "rm -rf ./build /tmp/notmine" "Allow")
  assert_decision "$out" "allow"
}

run_test "non-rm command -> silent" test_no_rm
run_test "rm without -r -> silent" test_rm_without_r_flag
run_test "rm -rf ./build (relative inside cwd) -> silent" test_rm_r_inside_cwd_relative
run_test "rm -rf <cwd>/build (absolute inside cwd) -> silent" test_rm_r_inside_cwd_absolute
run_test "rm -rf <home>/x -> silent" test_rm_r_inside_home
run_test "rm -rf ~/.cache/foo (shared cache) + Allow -> allow" test_rm_r_home_tilde
run_test "rm -rf ~/.cache/pre-commit + Deny -> deny" test_rm_r_shared_cache_deny
run_test "rm -rf ~/.npm + Deny -> deny" test_rm_r_npm_cache_dialog
run_test "rm -rf ~/Library/Caches/Homebrew + Deny -> deny" test_rm_r_macos_caches_dialog
run_test "rm -rf ~/non-cache-dir -> silent" test_rm_r_home_nonshared_silent
run_test "rm -rf /tmp/notmine + Allow -> permissionDecision=allow" test_rm_r_outside_both_pops_dialog
run_test "rm -rf /tmp/notmine + Deny -> permissionDecision=deny" test_rm_r_outside_both_deny
run_test "rm -rf /etc/foo -> deny (catastrophic, no dialog)" test_rm_r_catastrophic_root
run_test "rm -rf / -> deny" test_rm_r_catastrophic_root_path
run_test "rm -rf /usr/local/... -> deny" test_rm_r_catastrophic_usr
run_test "rm -rf /private/etc/... -> deny (macOS canonical form)" test_rm_r_catastrophic_private_etc
run_test "rm --recursive /etc/foo -> deny" test_rm_r_recursive_long_flag
run_test "multi-path with one catastrophic -> deny" test_rm_r_multiple_paths_one_catastrophic
run_test "multi-path with one outside-both -> dialog (allow)" test_rm_r_multiple_paths_one_dangerous

print_summary

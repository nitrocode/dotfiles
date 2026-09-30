#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-secret-scan-block.sh:"

HOOK="$HOOKS_DIR/secret-scan-block.sh"

run_with() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$input" | bash "$HOOK"
}

test_clean_command_is_silent() {
  local out; out=$(run_with 'ls -la')
  assert_empty "$out"
}

test_empty_command_is_silent() {
  local out; out=$(run_with '')
  assert_empty "$out"
}

test_fake_github_token_denies() {
  # A structurally valid-looking but fabricated PAT -- trufflehog's Github
  # detector matches on shape (regex + checksum), not a real API call
  # (--no-verification), so a synthetic token is enough to exercise this.
  local out; out=$(run_with 'echo "token=gho_16C7e42F292c6912E7710c838347Ae178B4a"')
  assert_decision "$out" "deny"
}

test_fake_token_embedded_in_larger_command_denies() {
  local out; out=$(run_with 'curl -H "Authorization: Bearer gho_16C7e42F292c6912E7710c838347Ae178B4a" https://api.example.com')
  assert_decision "$out" "deny"
}

test_missing_tool_input_command_is_silent() {
  local out; out=$(printf '%s' '{"tool_name":"Bash","tool_input":{}}' | bash "$HOOK")
  assert_empty "$out"
}

test_fails_open_when_trufflehog_missing() {
  # Symlink every tool the hook needs EXCEPT trufflehog into a sandbox dir,
  # so `command -v trufflehog` genuinely misses while jq/head/bash still
  # resolve -- a PATH cut that also removed jq would make this test pass
  # for the wrong reason (jq missing, not trufflehog).
  local sandbox out
  sandbox=$(mktemp -d)
  for tool in jq head cat bash; do
    real=$(command -v "$tool") && ln -s "$real" "$sandbox/$tool"
  done
  out=$(run_with_path "$sandbox" 'echo "gho_16C7e42F292c6912E7710c838347Ae178B4a"')
  rm -rf "$sandbox"
  assert_empty "$out"
}

run_with_path() {
  local fake_bin_dir="$1" cmd="$2"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  # bash itself is symlinked into fake_bin_dir (not just referenced from the
  # real PATH) so the outer command lookup for `bash` doesn't silently fall
  # back to the real PATH and defeat the point of this test.
  printf '%s' "$input" | PATH="$fake_bin_dir" "$fake_bin_dir/bash" "$HOOK"
}

run_test "clean command produces no output" test_clean_command_is_silent
run_test "empty command produces no output" test_empty_command_is_silent
run_test "fake GitHub token denies" test_fake_github_token_denies
run_test "fake token embedded in a larger command denies" test_fake_token_embedded_in_larger_command_denies
run_test "missing tool_input.command produces no output" test_missing_tool_input_command_is_silent
run_test "fails open (no output) when trufflehog is not on PATH" test_fails_open_when_trufflehog_missing

print_summary

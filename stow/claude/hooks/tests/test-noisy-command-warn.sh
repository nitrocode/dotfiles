#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-noisy-command-warn.sh:"

HOOK="$HOOKS_DIR/noisy-command-warn.sh"

run_with() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$input" | bash "$HOOK"
}

assert_warns() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"Noisy command"*) return 0;;
    *)
      printf '    expected a noisy-command warning, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

test_npm_install_no_flag_warns() {
  local out; out=$(run_with 'npm install')
  assert_warns "$out"
}

test_npm_install_silent_flag_silent() {
  local out; out=$(run_with 'npm install --silent')
  assert_empty "$out"
}

test_npm_ci_short_flag_silent() {
  local out; out=$(run_with 'npm ci -s')
  assert_empty "$out"
}

test_git_log_no_flag_warns() {
  local out; out=$(run_with 'git log')
  assert_warns "$out"
}

test_git_log_oneline_silent() {
  local out; out=$(run_with 'git log --oneline')
  assert_empty "$out"
}

test_git_log_dash1_silent() {
  local out; out=$(run_with 'git log -1')
  assert_empty "$out"
}

test_docker_build_no_flag_warns() {
  local out; out=$(run_with 'docker build .')
  assert_warns "$out"
}

test_docker_build_q_flag_silent() {
  local out; out=$(run_with 'docker build -q .')
  assert_empty "$out"
}

test_kubectl_get_no_flag_warns() {
  local out; out=$(run_with 'kubectl get pods')
  assert_warns "$out"
}

test_kubectl_get_o_flag_silent() {
  local out; out=$(run_with 'kubectl get pods -o wide')
  assert_empty "$out"
}

test_unrelated_command_silent() {
  local out; out=$(run_with 'ls -la')
  assert_empty "$out"
}

test_empty_command_silent() {
  local out; out=$(printf '%s' '{"tool_name":"Bash","tool_input":{}}' | bash "$HOOK")
  assert_empty "$out"
}

run_test "npm install no flag -> warns" test_npm_install_no_flag_warns
run_test "npm install --silent -> silent" test_npm_install_silent_flag_silent
run_test "npm ci -s -> silent" test_npm_ci_short_flag_silent
run_test "git log no flag -> warns" test_git_log_no_flag_warns
run_test "git log --oneline -> silent" test_git_log_oneline_silent
run_test "git log -1 -> silent" test_git_log_dash1_silent
run_test "docker build no flag -> warns" test_docker_build_no_flag_warns
run_test "docker build -q -> silent" test_docker_build_q_flag_silent
run_test "kubectl get no flag -> warns" test_kubectl_get_no_flag_warns
run_test "kubectl get -o -> silent" test_kubectl_get_o_flag_silent
run_test "unrelated command -> silent" test_unrelated_command_silent
run_test "empty command -> silent" test_empty_command_silent

print_summary

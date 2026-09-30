#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-block-dangerous.sh:"

run_block() {
  local cmd="$1"
  local input
  input=$(jq -nc --arg cmd "$cmd" '{tool_input:{command:$cmd},cwd:"/tmp"}')
  printf '%s' "$input" | bash "$HOOKS_DIR/block-dangerous.sh"
}

# Hard denies remaining
test_git_force_push_long_flag() {
  local out; out=$(run_block "git push origin main --force")
  assert_decision "$out" "deny"
}

test_git_force_push_short_flag() {
  local out; out=$(run_block "git push -f origin main")
  assert_decision "$out" "deny"
}

test_git_reset_hard() {
  local out; out=$(run_block "git reset --hard HEAD~1")
  assert_decision "$out" "deny"
}

test_git_clean_f() {
  local out; out=$(run_block "git clean -fd")
  assert_decision "$out" "deny"
}

test_git_branch_force_delete() {
  local out; out=$(run_block "git branch -D feature-x")
  assert_decision "$out" "deny"
}

test_docker_push() {
  local out; out=$(run_block "docker push myimage:tag")
  assert_decision "$out" "deny"
}

test_docker_prune() {
  local out; out=$(run_block "docker system prune -af")
  assert_decision "$out" "deny"
}

test_terraform_auto_approve() {
  local out; out=$(run_block "terraform apply -auto-approve")
  assert_decision "$out" "deny"
}

test_atmos_terraform_auto_approve() {
  local out; out=$(run_block "atmos terraform apply -auto-approve -stack prod")
  assert_decision "$out" "deny"
}

# Ask patterns (supply-chain pause)
test_pip_install_asks() {
  local out; out=$(run_block "pip install requests")
  assert_decision "$out" "ask"
}

test_npm_install_asks() {
  local out; out=$(run_block "npm install lodash")
  assert_decision "$out" "ask"
}

test_brew_install_asks() {
  local out; out=$(run_block "brew install jq")
  assert_decision "$out" "ask"
}

# Lockfile-driven installs: no new package named, skip the ask
test_pip_install_requirements_no_ask() {
  local out; out=$(run_block "pip install -r requirements.txt")
  assert_empty "$out"
}

test_pip_install_requirement_long_flag_no_ask() {
  local out; out=$(run_block "pip install --requirement requirements.txt")
  assert_empty "$out"
}

test_npm_install_bare_no_ask() {
  local out; out=$(run_block "npm install")
  assert_empty "$out"
}

test_npm_i_bare_no_ask() {
  local out; out=$(run_block "npm i")
  assert_empty "$out"
}

test_npm_install_bare_with_flags_no_ask() {
  local out; out=$(run_block "npm install --production")
  assert_empty "$out"
}

test_npm_install_with_package_still_asks() {
  local out; out=$(run_block "npm install lodash")
  assert_decision "$out" "ask"
}

# Delegated away (block-dangerous should NOT decide on these anymore)
test_rm_rf_no_decision() {
  local out; out=$(run_block "rm -rf ./build")
  assert_empty "$out"
}

test_kubectl_delete_no_decision() {
  local out; out=$(run_block "kubectl delete pod mypod")
  assert_empty "$out"
}

test_terraform_destroy_no_decision() {
  local out; out=$(run_block "terraform destroy")
  assert_empty "$out"
}

test_terraform_apply_no_decision() {
  # Plain terraform apply (no -auto-approve) should pass; dialog handles it elsewhere
  local out; out=$(run_block "terraform apply")
  assert_empty "$out"
}

# Benign commands pass through
test_ls_silent() {
  local out; out=$(run_block "ls -la")
  assert_empty "$out"
}

test_empty_command() {
  local out; out=$(run_block "")
  assert_empty "$out"
}

run_test "git push --force -> deny" test_git_force_push_long_flag
run_test "git push -f -> deny" test_git_force_push_short_flag
run_test "git reset --hard -> deny" test_git_reset_hard
run_test "git clean -fd -> deny" test_git_clean_f
run_test "git branch -D -> deny" test_git_branch_force_delete
run_test "docker push -> deny" test_docker_push
run_test "docker system prune -> deny" test_docker_prune
run_test "terraform apply -auto-approve -> deny" test_terraform_auto_approve
run_test "atmos terraform apply -auto-approve -> deny" test_atmos_terraform_auto_approve
run_test "pip install -> ask" test_pip_install_asks
run_test "npm install -> ask" test_npm_install_asks
run_test "brew install -> ask" test_brew_install_asks
run_test "pip install -r requirements.txt -> no ask" test_pip_install_requirements_no_ask
run_test "pip install --requirement requirements.txt -> no ask" test_pip_install_requirement_long_flag_no_ask
run_test "npm install (bare) -> no ask" test_npm_install_bare_no_ask
run_test "npm i (bare) -> no ask" test_npm_i_bare_no_ask
run_test "npm install --production (flags only) -> no ask" test_npm_install_bare_with_flags_no_ask
run_test "npm install lodash (explicit package) -> ask" test_npm_install_with_package_still_asks
run_test "rm -rf (delegated to rm-confirm) -> no decision here" test_rm_rf_no_decision
run_test "kubectl delete (delegated) -> no decision here" test_kubectl_delete_no_decision
run_test "terraform destroy (delegated) -> no decision here" test_terraform_destroy_no_decision
run_test "terraform apply (delegated) -> no decision here" test_terraform_apply_no_decision
run_test "ls -la (harmless) -> silent" test_ls_silent
run_test "empty command -> silent" test_empty_command

print_summary

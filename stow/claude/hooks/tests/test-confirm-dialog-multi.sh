#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-confirm-dialog-multi.sh:"

HOOK="$HOOKS_DIR/confirm-dialog-multi.sh"

# Three-pattern fixture: terraform apply/destroy, kubectl delete, aws delete/terminate/destroy/rm.
PATTERNS=(
  --pattern 'terraform[[:space:]]+(apply|destroy)' --reason 'Modifies or destroys Terraform-managed infrastructure'
  --pattern '(^|[;&|][[:space:]]*)kubectl[[:space:]]+delete' --reason 'Deletes Kubernetes resources'
  --pattern '(^|[;&|][[:space:]]*)aws[[:space:]].*[[:space:]](delete-|terminate-|destroy-|rm[[:space:]])' --reason 'Destroys AWS resources'
)

run_with() {
  local cmd="$1" response="$2"
  local input
  input=$(jq -nc --arg cmd "$cmd" '{tool_input:{command:$cmd},cwd:"/tmp"}')
  printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE="$response" bash "$HOOK" "${PATTERNS[@]}"
}

test_tf_apply_allow() {
  local out; out=$(run_with 'terraform apply' Allow)
  assert_decision "$out" "allow"
}

test_kubectl_delete_deny() {
  local out; out=$(run_with 'kubectl delete pod foo' Deny)
  assert_decision "$out" "deny"
}

test_aws_terminate_allow() {
  local out; out=$(run_with 'aws ec2 terminate-instances --instance-ids i-1' Allow)
  assert_decision "$out" "allow"
}

test_atmos_terraform_apply_allow() {
  local out; out=$(run_with 'atmos terraform apply -stack prod' Allow)
  assert_decision "$out" "allow"
}

test_no_pattern_match_silent() {
  local out; out=$(run_with 'ls -la' Allow)
  assert_empty "$out"
}

test_kubectl_apply_silent() {
  # kubectl apply is NOT in the pattern list.
  local out; out=$(run_with 'kubectl apply -f manifest.yaml' Allow)
  assert_empty "$out"
}

test_empty_command_silent() {
  local input='{"tool_input":{},"cwd":"/tmp"}'
  local out
  out=$(printf '%s' "$input" | CONFIRM_DIALOG_RESPONSE=Allow bash "$HOOK" "${PATTERNS[@]}")
  assert_empty "$out"
}

test_first_match_wins() {
  # Command matches both terraform AND aws patterns (a pipeline with both).
  # Should match the first pattern in the list (terraform).
  local out; out=$(run_with 'terraform apply && aws ec2 terminate-instances --instance-ids i-1' Deny)
  assert_decision "$out" "deny"
}

test_unknown_response_denies() {
  local out; out=$(run_with 'terraform destroy' unknown)
  assert_decision "$out" "deny"
}

test_missing_args_errors() {
  local input='{"tool_input":{"command":"ls"},"cwd":"/tmp"}'
  if printf '%s' "$input" | bash "$HOOK" 2>/dev/null; then
    return 1
  fi
  return 0
}

test_mismatched_args_errors() {
  local input='{"tool_input":{"command":"ls"},"cwd":"/tmp"}'
  if printf '%s' "$input" | bash "$HOOK" --pattern 'foo' 2>/dev/null; then
    return 1
  fi
  return 0
}

session_allow_key_hash() {
  # Mirrors confirm-dialog-multi.sh's KEY_TEXT="${MATCHED_REASON}|cwd:${CWD}|${PROFILE}" formula.
  local category="$1" cwd="$2" profile="${3:-}"
  local key_text="${category}|cwd:${cwd}|${profile}"
  printf '%s' "$key_text" | md5 -q 2>/dev/null || printf '%s' "$key_text" | md5sum | cut -d' ' -f1
}

test_allow_for_session_persists() {
  local sid="test-multi-session-allow-$$"
  local key_hash flag_dir flag_file
  key_hash=$(session_allow_key_hash 'Destroys AWS resources' '/tmp')
  flag_dir="/tmp/claude-dialog-session-allow"
  flag_file="${flag_dir}/${sid}_${key_hash}.flag"
  rm -f "$flag_file"

  local input1
  input1=$(jq -nc --arg sid "$sid" '{tool_input:{command:"aws ec2 terminate-instances --instance-ids i-1"},cwd:"/tmp",session_id:$sid}')
  local out1
  out1=$(printf '%s' "$input1" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOK" "${PATTERNS[@]}")

  if ! assert_decision "$out1" "allow"; then rm -f "$flag_file"; return 1; fi
  if [ ! -f "$flag_file" ]; then
    printf '    expected session-allow flag file at %s\n' "$flag_file" >&2
    return 1
  fi

  # Second call, same session, same reason category (aws destroy), different command,
  # no response override: the flag should short-circuit straight to allow.
  local input2
  input2=$(jq -nc --arg sid "$sid" '{tool_input:{command:"aws s3 rm s3://bucket/key"},cwd:"/tmp",session_id:$sid}')
  local out2
  out2=$(printf '%s' "$input2" | bash "$HOOK" "${PATTERNS[@]}")

  rm -f "$flag_file"
  assert_decision "$out2" "allow"
}

test_allow_for_session_does_not_cover_other_category() {
  # Session-allow on "aws destroy" must not also silently allow the unrelated
  # "kubectl delete" category in the same session.
  local sid="test-multi-session-allow-cross-$$"
  local aws_hash k8s_hash flag_dir
  aws_hash=$(session_allow_key_hash 'Destroys AWS resources' '/tmp')
  k8s_hash=$(session_allow_key_hash 'Deletes Kubernetes resources' '/tmp')
  flag_dir="/tmp/claude-dialog-session-allow"
  rm -f "${flag_dir}/${sid}_${aws_hash}.flag" "${flag_dir}/${sid}_${k8s_hash}.flag"

  local input1
  input1=$(jq -nc --arg sid "$sid" '{tool_input:{command:"aws ec2 terminate-instances --instance-ids i-1"},cwd:"/tmp",session_id:$sid}')
  printf '%s' "$input1" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOK" "${PATTERNS[@]}" > /dev/null

  local input2
  input2=$(jq -nc --arg sid "$sid" '{tool_input:{command:"kubectl delete pod foo"},cwd:"/tmp",session_id:$sid}')
  local out2
  out2=$(printf '%s' "$input2" | CONFIRM_DIALOG_RESPONSE=Deny bash "$HOOK" "${PATTERNS[@]}")

  rm -f "${flag_dir}/${sid}_${aws_hash}.flag" "${flag_dir}/${sid}_${k8s_hash}.flag"
  assert_decision "$out2" "deny"
}

test_allow_for_session_does_not_cover_other_profile() {
  # Session-allow granted for one AWS --profile must not cover a destroy
  # command against a different --profile (different account), even though
  # both fall under the same "Destroys AWS resources" category.
  local sid="test-multi-session-allow-profile-$$"
  local hash_dev hash_prod flag_dir
  hash_dev=$(session_allow_key_hash 'Destroys AWS resources' '/tmp' '--profile dev-account')
  hash_prod=$(session_allow_key_hash 'Destroys AWS resources' '/tmp' '--profile prod-account')
  flag_dir="/tmp/claude-dialog-session-allow"
  rm -f "${flag_dir}/${sid}_${hash_dev}.flag" "${flag_dir}/${sid}_${hash_prod}.flag"

  local input1
  input1=$(jq -nc --arg sid "$sid" '{tool_input:{command:"aws ec2 terminate-instances --instance-ids i-1 --profile dev-account"},cwd:"/tmp",session_id:$sid}')
  printf '%s' "$input1" | CONFIRM_DIALOG_RESPONSE="Allow for session" bash "$HOOK" "${PATTERNS[@]}" > /dev/null

  local input2
  input2=$(jq -nc --arg sid "$sid" '{tool_input:{command:"aws ec2 terminate-instances --instance-ids i-2 --profile prod-account"},cwd:"/tmp",session_id:$sid}')
  local out2
  out2=$(printf '%s' "$input2" | CONFIRM_DIALOG_RESPONSE=Deny bash "$HOOK" "${PATTERNS[@]}")

  rm -f "${flag_dir}/${sid}_${hash_dev}.flag" "${flag_dir}/${sid}_${hash_prod}.flag"
  assert_decision "$out2" "deny"
}

run_test "terraform apply matches pattern 1 -> allow" test_tf_apply_allow
run_test "kubectl delete matches pattern 2 -> deny" test_kubectl_delete_deny
run_test "aws terminate matches pattern 3 -> allow" test_aws_terminate_allow
run_test "atmos terraform apply matches pattern 1 -> allow" test_atmos_terraform_apply_allow
run_test "no pattern match -> silent" test_no_pattern_match_silent
run_test "kubectl apply (not in list) -> silent" test_kubectl_apply_silent
run_test "empty command -> silent" test_empty_command_silent
run_test "first matching pattern wins" test_first_match_wins
run_test "unknown response defaults to deny" test_unknown_response_denies
run_test "no args -> error exit 2" test_missing_args_errors
run_test "odd number of args -> error exit 2" test_mismatched_args_errors
run_test "Allow for session -> allow + persists for next match, same category" test_allow_for_session_persists
run_test "Allow for session on one category does not cover another" test_allow_for_session_does_not_cover_other_category
run_test "Allow for session on one --profile does not cover another" test_allow_for_session_does_not_cover_other_profile

print_summary

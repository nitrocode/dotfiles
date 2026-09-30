#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-cheatsheet-reminder.sh:"

HOOK="$HOOKS_DIR/cheatsheet-reminder.sh"
SANDBOXES=()

run_with() {
  local prompt="$1"
  local sandbox_config_dir="$2"
  local input
  input=$(jq -nc --arg p "$prompt" '{prompt:$p}')
  printf '%s' "$input" | CLAUDE_CONFIG_DIR="$sandbox_config_dir" bash "$HOOK"
}

new_sandbox() {
  local d; d=$(mktemp -d)
  mkdir -p "$d/logs" "$d/cheatsheets"
  SANDBOXES+=("$d")
  echo "$d"
}

cleanup_sandboxes() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    [[ -n "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_sandboxes EXIT

test_no_cli_mention_exits_zero() {
  local sb; sb=$(new_sandbox)
  run_with "i keep getting this error" "$sb" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

test_cli_mention_missing_cheatsheet_exits_zero() {
  local sb; sb=$(new_sandbox)
  run_with "run kubectl get pods" "$sb" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

test_cli_mention_missing_cheatsheet_logs_candidate() {
  local sb; sb=$(new_sandbox)
  run_with "run kubectl get pods" "$sb" >/dev/null 2>&1
  grep -q "kubectl-get" "$sb/logs/cheatsheet-candidates.log" 2>/dev/null
}

test_cli_mention_existing_cheatsheet_prints_notice() {
  local sb; sb=$(new_sandbox)
  echo "# stub" > "$sb/cheatsheets/kubectl-get.md"
  local out
  out=$(run_with "run kubectl get pods" "$sb" 2>&1)
  assert_contains "$out" "Cheatsheets available"
}

test_empty_prompt_exits_zero() {
  local sb; sb=$(new_sandbox)
  run_with "" "$sb" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

run_test "no CLI mention -> exit 0" test_no_cli_mention_exits_zero
run_test "CLI mention, missing cheatsheet -> exit 0" test_cli_mention_missing_cheatsheet_exits_zero
run_test "CLI mention, missing cheatsheet -> logs candidate" test_cli_mention_missing_cheatsheet_logs_candidate
run_test "CLI mention, existing cheatsheet -> prints notice" test_cli_mention_existing_cheatsheet_prints_notice
run_test "empty prompt -> exit 0" test_empty_prompt_exits_zero

print_summary

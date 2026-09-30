#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/hooks/gh-pr-confirm.sh
set -u
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/hooks/gh-pr-confirm.sh"
echo "test-gh-pr-confirm.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/.claude/hooks"
  ORIG_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
  export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
  # Mock confirm-dialog.sh: just echo the REASON (arg 2) so we can assert on it,
  # instead of popping a real macOS dialog.
  cat >"$CLAUDE_CONFIG_DIR/hooks/confirm-dialog.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
printf '%s' "$2"
EOF
  chmod +x "$CLAUDE_CONFIG_DIR/hooks/confirm-dialog.sh" 2>/dev/null
}

teardown_sandbox() {
  export CLAUDE_CONFIG_DIR="$ORIG_CLAUDE_CONFIG_DIR"
  rm -rf "$SANDBOX"
}

run_hook() {
  printf '%s' "$1" | bash "$SCRIPT"
}

test_conventional_title_no_warning() {
  setup_sandbox
  local out
  out=$(run_hook '{"tool_input":{"command":"gh pr create --title \"feat(scope): add thing\" --body x"}}')
  teardown_sandbox
  case "$out" in
    *WARNING*) return 1 ;;
    *) return 0 ;;
  esac
}

test_non_conventional_title_warns() {
  setup_sandbox
  local out
  out=$(run_hook '{"tool_input":{"command":"gh pr create --title \"add thing\" --body x"}}')
  teardown_sandbox
  assert_contains "$out" "WARNING"
}

test_non_gh_pr_create_command_no_op() {
  setup_sandbox
  local out
  out=$(run_hook '{"tool_input":{"command":"gh pr list"}}')
  teardown_sandbox
  assert_empty "$out"
}

test_missing_title_no_crash_no_warning() {
  setup_sandbox
  local out rc
  out=$(run_hook '{"tool_input":{"command":"gh pr create --body x"}}')
  rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ] && case "$out" in *WARNING*) return 1 ;; *) return 0 ;; esac
}

test_conventional_title_with_scope_and_ticket_no_warning() {
  setup_sandbox
  local out
  out=$(run_hook '{"tool_input":{"command":"gh pr create --title \"fix(auth): handle expired token (PROJ-123)\""}}')
  teardown_sandbox
  case "$out" in
    *WARNING*) return 1 ;;
    *) return 0 ;;
  esac
}

run_test "conventional title -> no warning"                    test_conventional_title_no_warning
run_test "non-conventional title -> warning"                    test_non_conventional_title_warns
run_test "non gh-pr-create command -> no-op"                     test_non_gh_pr_create_command_no_op
run_test "missing --title -> no crash, no warning"               test_missing_title_no_crash_no_warning
run_test "conventional title with scope+ticket -> no warning"   test_conventional_title_with_scope_and_ticket_no_warning

print_summary

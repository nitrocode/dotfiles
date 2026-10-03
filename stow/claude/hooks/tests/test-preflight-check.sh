#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-preflight-check.sh:"

HOOK="$HOOKS_DIR/preflight-check.sh"

# preflight-check.sh resolves the login script via $HOME at runtime, so
# overriding HOME per-invocation lets us swap in a fake without touching
# the real ensure-saas-login.sh.
run_with_fake_login_script() {
  local body="$1"
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/scripts"
  cat > "$sandbox/.claude/scripts/ensure-saas-login.sh" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$sandbox/.claude/scripts/ensure-saas-login.sh"
  HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK"
  local rc=$?
  rm -rf "$sandbox"
  return $rc
}

test_all_logged_in_prints_nothing() {
  local out
  out=$(run_with_fake_login_script 'echo "All services logged in."; exit 0' 2>&1)
  assert_empty "$out"
}

test_logged_out_services_surface_warning() {
  local out
  out=$(run_with_fake_login_script 'echo "Not logged in:"; echo "  - 1Password (op)"; exit 1' 2>&1)
  assert_contains "$out" "SaaS auth issue" && assert_contains "$out" "  - 1Password (op)"
}

test_hook_exits_zero_even_when_services_logged_out() {
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/scripts"
  cat > "$sandbox/.claude/scripts/ensure-saas-login.sh" <<'EOF'
#!/usr/bin/env bash
echo "Not logged in:"
echo "  - Cycode"
exit 1
EOF
  chmod +x "$sandbox/.claude/scripts/ensure-saas-login.sh"
  HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK" >/dev/null 2>&1
  local rc=$?
  rm -rf "$sandbox"
  [ "$rc" -eq 0 ]
}

test_missing_login_script_warns_but_does_not_fail() {
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/scripts"
  # deliberately do not create ensure-saas-login.sh
  local out
  out=$(HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK" 2>&1)
  local rc=$?
  rm -rf "$sandbox"
  assert_contains "$out" "not found" && [ "$rc" -eq 0 ]
}

test_slow_login_script_times_out_without_hanging_hook() {
  local out
  local start end elapsed
  start=$(date +%s)
  out=$(run_with_fake_login_script 'sleep 40; exit 0' 2>&1)
  end=$(date +%s)
  elapsed=$((end - start))
  # must return well under the 40s sleep, proving the 20s timeout fired
  assert_contains "$out" "timed out" && [ "$elapsed" -lt 30 ]
}

run_test "all logged in prints nothing" test_all_logged_in_prints_nothing
run_test "logged-out services surface a warning with details" test_logged_out_services_surface_warning
run_test "hook exits 0 even when services are logged out (non-blocking)" test_hook_exits_zero_even_when_services_logged_out
run_test "missing ensure-saas-login.sh warns but does not fail the hook" test_missing_login_script_warns_but_does_not_fail
run_test "a hanging login script is killed by the 5s timeout" test_slow_login_script_times_out_without_hanging_hook

print_summary

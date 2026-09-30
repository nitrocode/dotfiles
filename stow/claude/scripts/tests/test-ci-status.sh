#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/ci-status.sh.
# Mocks `gh` via a PATH shim so no real GitHub API call happens.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/ci-status.sh"
echo "test-ci-status.sh:"

setup_bin() {
  BINDIR=$(mktemp -d)
  export PATH="$BINDIR:$PATH"
}

teardown_bin() {
  rm -rf "$BINDIR"
}

write_gh_stub() {
  cat >"$BINDIR/gh" <<EOF
#!/bin/bash
cat <<'PAYLOAD'
$1
PAYLOAD
EOF
  chmod +x "$BINDIR/gh"
}

test_bad_args() {
  setup_bin
  local out
  out=$("$SCRIPT" 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 2 ]] && assert_contains "$out" "Usage:"
}

test_fails_loud_on_malformed_response() {
  setup_bin
  write_gh_stub '{}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 4 ]] && assert_contains "$out" "unexpected response shape"
}

test_no_checks_yet() {
  setup_bin
  write_gh_stub '{"statusCheckRollup":[]}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 3 ]] && assert_contains "$out" "No CI checks reported"
}

test_all_pass() {
  setup_bin
  write_gh_stub '{"statusCheckRollup":[{"name":"build","conclusion":"SUCCESS"},{"name":"test","conclusion":"SUCCESS"}]}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "All checks passed."
}

test_reports_failure() {
  setup_bin
  write_gh_stub '{"statusCheckRollup":[{"name":"build","conclusion":"SUCCESS"},{"name":"test","conclusion":"FAILURE"}]}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "1 check(s) failed."
}

test_reports_pending_over_pass() {
  setup_bin
  write_gh_stub '{"statusCheckRollup":[{"name":"build","conclusion":"SUCCESS"},{"name":"test","state":"PENDING"}]}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 3 ]] && assert_contains "$out" "still pending"
}

test_gh_call_failure_propagates() {
  setup_bin
  cat >"$BINDIR/gh" <<'EOF'
#!/bin/bash
echo "not found" >&2
exit 1
EOF
  chmod +x "$BINDIR/gh"
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 4 ]] && assert_contains "$out" "gh pr view failed"
}

run_test "bad args show usage" test_bad_args
run_test "fails loud on malformed response" test_fails_loud_on_malformed_response
run_test "reports no checks yet distinctly" test_no_checks_yet
run_test "all pass -> exit 0" test_all_pass
run_test "reports failure count" test_reports_failure
run_test "pending beats false pass" test_reports_pending_over_pass
run_test "propagates gh call failure" test_gh_call_failure_propagates

print_summary

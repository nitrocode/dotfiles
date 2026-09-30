#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/pr-unresolved-threads.sh.
# Mocks `gh` via a PATH shim so no real GitHub API call happens.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/pr-unresolved-threads.sh"
echo "test-pr-unresolved-threads.sh:"

setup_bin() {
  BINDIR=$(mktemp -d)
  export PATH="$BINDIR:$PATH"
}

teardown_bin() {
  rm -rf "$BINDIR"
}

write_gh_stub() {
  # $1 = raw stdout for `gh api graphql ...`
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

test_rejects_bad_repo_form() {
  setup_bin
  local out
  out=$("$SCRIPT" notarepo 5 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 2 ]] && assert_contains "$out" "owner/repo form"
}

test_fails_loud_on_malformed_response() {
  setup_bin
  write_gh_stub '{"data": {}}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "unexpected GraphQL response shape"
}

test_reports_zero_threads() {
  setup_bin
  write_gh_stub '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "No review threads at all"
}

test_reports_all_resolved() {
  setup_bin
  write_gh_stub '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[
    {"isResolved":true,"comments":{"nodes":[{"url":"https://x/1","body":"a"}]}},
    {"isResolved":true,"comments":{"nodes":[{"url":"https://x/2","body":"b"}]}}
  ]}}}}}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "No unresolved threads. (2 total"
}

test_lists_unresolved_threads() {
  setup_bin
  write_gh_stub '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[
    {"isResolved":false,"comments":{"nodes":[{"url":"https://x/1","body":"fix this"}]}},
    {"isResolved":true,"comments":{"nodes":[{"url":"https://x/2","body":"resolved one"}]}}
  ]}}}}}'
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "https://x/1, fix this" && ! echo "$out" | grep -q "https://x/2"
}

test_gh_call_failure_propagates() {
  setup_bin
  cat >"$BINDIR/gh" <<'EOF'
#!/bin/bash
echo "auth error" >&2
exit 1
EOF
  chmod +x "$BINDIR/gh"
  local out
  out=$("$SCRIPT" acme/actions 598 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "gh api graphql call failed"
}

run_test "bad args show usage" test_bad_args
run_test "rejects malformed repo arg" test_rejects_bad_repo_form
run_test "fails loud on malformed GraphQL response" test_fails_loud_on_malformed_response
run_test "reports zero threads distinctly" test_reports_zero_threads
run_test "reports all-resolved distinctly" test_reports_all_resolved
run_test "lists only unresolved threads" test_lists_unresolved_threads
run_test "propagates gh call failure" test_gh_call_failure_propagates

print_summary

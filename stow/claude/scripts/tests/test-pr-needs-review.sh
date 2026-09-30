#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/pr-needs-review.sh.
# Mocks `gh` via a PATH shim so no real GitHub API call happens.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/pr-needs-review.sh"
echo "test-pr-needs-review.sh:"

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
  write_gh_stub '{"not":"an array"}'
  local out
  out=$("$SCRIPT" acme/actions 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "unexpected response shape"
}

test_reports_none_needing_review() {
  setup_bin
  write_gh_stub '[{"number":1,"title":"a","url":"https://x/1","reviews":[{"id":1}],"reviewRequests":[]}]'
  local out
  out=$("$SCRIPT" acme/actions 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "No open PRs need review. (1 open"
}

test_lists_prs_needing_review() {
  setup_bin
  write_gh_stub '[
    {"number":1,"title":"needs review","url":"https://x/1","reviews":[],"reviewRequests":[]},
    {"number":2,"title":"already reviewed","url":"https://x/2","reviews":[{"id":1}],"reviewRequests":[]}
  ]'
  local out
  out=$("$SCRIPT" acme/actions 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "#1  needs review" && ! echo "$out" | grep -q "#2"
}

test_warns_on_limit_truncation() {
  setup_bin
  # Build exactly 100 minimal PR objects.
  local items="" i
  for i in $(seq 1 100); do
    items+="{\"number\":$i,\"title\":\"pr $i\",\"url\":\"https://x/$i\",\"reviews\":[{\"id\":1}],\"reviewRequests\":[]},"
  done
  write_gh_stub "[${items%,}]"
  local out
  out=$("$SCRIPT" acme/actions 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 0 ]] && assert_contains "$out" "hit the 100-item --limit"
}

test_gh_call_failure_propagates() {
  setup_bin
  cat >"$BINDIR/gh" <<'EOF'
#!/bin/bash
echo "rate limited" >&2
exit 1
EOF
  chmod +x "$BINDIR/gh"
  local out
  out=$("$SCRIPT" acme/actions 2>&1); local code=$?
  teardown_bin
  [[ $code -eq 1 ]] && assert_contains "$out" "gh pr list failed"
}

run_test "bad args show usage" test_bad_args
run_test "fails loud on malformed response" test_fails_loud_on_malformed_response
run_test "reports none-needing-review distinctly" test_reports_none_needing_review
run_test "lists only PRs needing review" test_lists_prs_needing_review
run_test "warns on 100-item limit truncation" test_warns_on_limit_truncation
run_test "propagates gh call failure" test_gh_call_failure_propagates

print_summary

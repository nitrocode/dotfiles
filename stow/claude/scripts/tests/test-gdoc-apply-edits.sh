#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/gdoc-apply-edits.sh.
# Mocks the `clasp` CLI via a PATH shim that records invocation args to a state
# file. Verifies arg parsing, JSON validation, payload construction, and error
# propagation. Does not hit any Google API.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/gdoc-apply-edits.sh"
echo "test-gdoc-apply-edits.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/state"
  export CLASP_LOG="$SANDBOX/state/clasp-calls.txt"
  : >"$CLASP_LOG"

  cat >"$SANDBOX/bin/clasp" <<'CLASP'
#!/bin/bash
# Mock clasp. Records args + cwd to $CLASP_LOG, then exits with
# $CLASP_MOCK_EXIT_CODE (default 0) and prints $CLASP_MOCK_STDOUT.
echo "cwd=$(pwd)" >>"$CLASP_LOG"
echo "args=$*" >>"$CLASP_LOG"
if [[ -n "${CLASP_MOCK_STDOUT:-}" ]]; then
  printf '%s\n' "$CLASP_MOCK_STDOUT"
fi
exit "${CLASP_MOCK_EXIT_CODE:-0}"
CLASP
  chmod +x "$SANDBOX/bin/clasp"
  export CLASP_BIN="$SANDBOX/bin/clasp"
  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown_sandbox() {
  export PATH="$ORIG_PATH"
  rm -rf "$SANDBOX"
  unset CLASP_BIN CLASP_LOG CLASP_MOCK_EXIT_CODE CLASP_MOCK_STDOUT
}

# 1. Happy path: file-based edits, valid JSON array.
test_happy_path() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  cat >"$edits" <<'JSON'
[{"type":"replace","find":"3 Flavors","replace":"4 Flavors"}]
JSON
  export CLASP_MOCK_STDOUT='{"applied":1,"skipped":[],"errors":[]}'
  local out rc
  out=$("$SCRIPT" --doc-id "abc123" --edits "$edits" 2>&1) || rc=$?
  rc="${rc:-0}"
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" '"applied":1' || { teardown_sandbox; return 1; }
  assert_contains "$(cat "$CLASP_LOG")" "applyEdits" || { teardown_sandbox; return 1; }
  assert_contains "$(cat "$CLASP_LOG")" '"docId":"abc123"' || { teardown_sandbox; return 1; }
  assert_contains "$(cat "$CLASP_LOG")" '"3 Flavors"' || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 2. Stdin edits work the same.
test_stdin_edits() {
  setup_sandbox
  export CLASP_MOCK_STDOUT='{"applied":1,"skipped":[],"errors":[]}'
  local out rc
  out=$(printf '[{"type":"replace","find":"a","replace":"b"}]' \
    | "$SCRIPT" --doc-id "abc123" --edits-stdin 2>&1) || rc=$?
  rc="${rc:-0}"
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" '"applied":1' || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 3. Missing --doc-id.
test_missing_doc_id() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[]' >"$edits"
  local out rc=0
  out=$("$SCRIPT" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "--doc-id required" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 4. Missing both --edits and --edits-stdin.
test_missing_edits_source() {
  setup_sandbox
  local out rc=0
  out=$("$SCRIPT" --doc-id "abc123" 2>&1) || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "--edits FILE or --edits-stdin required" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 5. Invalid JSON in edits file.
test_invalid_json() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo 'not valid json' >"$edits"
  local out rc=0
  out=$("$SCRIPT" --doc-id "abc123" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "must be a top-level array" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 6. JSON object (not array) is rejected.
test_json_object_rejected() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '{"foo":"bar"}' >"$edits"
  local rc=0
  "$SCRIPT" --doc-id "abc123" --edits "$edits" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 7. Edits file not found.
test_missing_edits_file() {
  setup_sandbox
  local rc=0
  "$SCRIPT" --doc-id "abc123" --edits "$SANDBOX/nope.json" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "    expected rc=2, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 8. clasp failure propagates exit code.
test_clasp_failure_propagates() {
  setup_sandbox
  local edits="$SANDBOX/edits.json"
  echo '[]' >"$edits"
  export CLASP_MOCK_EXIT_CODE=7
  local rc=0
  "$SCRIPT" --doc-id "abc123" --edits "$edits" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "7" ] || { echo "    expected rc=7, got $rc"; teardown_sandbox; return 1; }
  teardown_sandbox
}

# 9. clasp not installed (override CLASP_BIN to nonexistent path).
test_clasp_not_installed() {
  setup_sandbox
  export CLASP_BIN="$SANDBOX/bin/does-not-exist"
  local edits="$SANDBOX/edits.json"
  echo '[]' >"$edits"
  local out rc=0
  out=$("$SCRIPT" --doc-id "abc123" --edits "$edits" 2>&1) || rc=$?
  [ "$rc" = "3" ] || { echo "    expected rc=3, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "clasp not installed" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

# 10. Help flag prints usage and exits 0.
test_help_flag() {
  setup_sandbox
  local out rc=0
  out=$("$SCRIPT" --help 2>&1) || rc=$?
  [ "$rc" = "0" ] || { echo "    expected rc=0, got $rc"; teardown_sandbox; return 1; }
  assert_contains "$out" "doc-id" || { teardown_sandbox; return 1; }
  teardown_sandbox
}

run_test "happy path file-based edits" test_happy_path
run_test "stdin edits" test_stdin_edits
run_test "missing --doc-id" test_missing_doc_id
run_test "missing edits source" test_missing_edits_source
run_test "invalid JSON" test_invalid_json
run_test "JSON object rejected" test_json_object_rejected
run_test "missing edits file" test_missing_edits_file
run_test "clasp failure propagates" test_clasp_failure_propagates
run_test "clasp not installed" test_clasp_not_installed
run_test "help flag" test_help_flag
print_summary

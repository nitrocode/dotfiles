#!/usr/bin/env bash
# Tests for laptop-migration-dry-run.sh
# Runs entirely inside a mktemp sandbox: fake files/dirs, a fake include list,
# no interaction with the real $HOME or $CLAUDE_CONFIG_DIR/scripts include list.

set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/laptop-migration-dry-run.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'
PASS=0; FAIL=0; FAILED_TESTS=()

run_test() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); printf "  ${GREEN}✓${RESET} %s\n" "$name"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); printf "  ${RED}✗${RESET} %s\n" "$name"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) printf '    expected to contain: %s\n    got: %s\n' "$needle" "$(printf '%s' "$haystack" | head -c 400)" >&2; return 1 ;;
  esac
}

setup_fixture() {
  # rebuild a clean fixture tree + include list for each test
  rm -rf "$SANDBOX/home" "$SANDBOX/list.txt" "$SANDBOX/list.local" "$SANDBOX/exclude.txt"
  mkdir -p "$SANDBOX/home/present_dir"
  echo "hello" > "$SANDBOX/home/present_dir/file.txt"
  echo "world" > "$SANDBOX/home/present_file.txt"
  cat > "$SANDBOX/list.txt" <<EOF
# a comment line, should be ignored

~/present_dir
~/present_file.txt
~/does_not_exist
EOF
}

setup_fixture_with_nested_exclude() {
  # a present_dir big enough that excluding the nested cache/ subdir changes
  # the reported total, not just the listing
  setup_fixture
  mkdir -p "$SANDBOX/home/present_dir/cache"
  head -c 200000 /dev/zero > "$SANDBOX/home/present_dir/cache/blob.bin"
  cat > "$SANDBOX/exclude.txt" <<EOF
# reproducible cache, should be netted out
~/present_dir/cache
EOF
}

test_reports_found_and_missing_counts() {
  setup_fixture
  local out
  out="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt")"
  assert_contains "$out" "Included paths: 2" && \
  assert_contains "$out" "Missing paths:  1" && \
  assert_contains "$out" "does_not_exist"
}

test_skips_comments_and_blank_lines() {
  setup_fixture
  local out
  out="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt")"
  # "a comment line" text itself should never appear as a reported path
  if printf '%s' "$out" | grep -q "a comment line"; then
    return 1
  fi
  return 0
}

test_missing_list_file_errors_nonzero() {
  bash "$SCRIPT" "$SANDBOX/no-such-list.txt" >/tmp/out.$$ 2>/tmp/err.$$
  local status=$?
  local err
  err="$(cat /tmp/err.$$)"
  rm -f "/tmp/out.$$" "/tmp/err.$$"
  [ "$status" -ne 0 ] && assert_contains "$err" "not readable"
}

test_reports_total_size_line() {
  setup_fixture
  local out
  out="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt")"
  assert_contains "$out" "Estimated total size:"
}

test_no_side_effects_no_archive_created() {
  setup_fixture
  HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt" >/dev/null
  # dry-run must never write an archive or mutate the fixture tree
  if find "$SANDBOX/home" -name '*.tar*' -o -name '*.zip' | grep -q .; then
    return 1
  fi
  [ -f "$SANDBOX/home/present_file.txt" ]
}

test_excluded_subpath_reported_and_netted_from_total() {
  setup_fixture_with_nested_exclude
  local out
  out="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt" "$SANDBOX/exclude.txt")"
  assert_contains "$out" "Excluded (regenerate/reinstall on new laptop" && \
  assert_contains "$out" "present_dir/cache" && \
  assert_contains "$out" "net of exclusions"
}

test_excluded_subpath_reduces_parent_size() {
  setup_fixture_with_nested_exclude
  local with_exclude without_exclude
  with_exclude="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt" "$SANDBOX/exclude.txt" | \
    grep "Estimated total size:" | grep -oE '\(([0-9]+) KB' | grep -oE '[0-9]+')"
  # nonexistent exclude file: script skips exclusion logic, parent size reported in full
  without_exclude="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt" "$SANDBOX/no-such-exclude.txt" | \
    grep "Estimated total size:" | grep -oE '\(([0-9]+) KB' | grep -oE '[0-9]+')"
  [ -n "$with_exclude" ] && [ -n "$without_exclude" ] && [ "$with_exclude" -lt "$without_exclude" ]
}

test_missing_exclude_file_does_not_error() {
  setup_fixture
  # no exclude.txt written for this test; script should just skip exclusion logic
  HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt" "$SANDBOX/no-such-exclude.txt" >"$SANDBOX/out.log" 2>"$SANDBOX/err.log"
  local status=$?
  [ "$status" -eq 0 ]
}

echo "Running laptop-migration-dry-run.sh tests..."
test_local_list_is_counted() {
  setup_fixture
  mkdir -p "$SANDBOX/home/private_dir"
  echo "x" > "$SANDBOX/home/private_dir/f"
  echo "~/private_dir" > "$SANDBOX/list.local"
  local out
  out="$(HOME="$SANDBOX/home" bash "$SCRIPT" "$SANDBOX/list.txt")"
  assert_contains "$out" "Included paths: 3" && \
  assert_contains "$out" "private_dir"
}

run_test "reports found/missing counts"        test_reports_found_and_missing_counts
run_test "skips comments and blank lines"       test_skips_comments_and_blank_lines
run_test "missing list file errors non-zero"    test_missing_list_file_errors_nonzero
run_test "reports total size line"              test_reports_total_size_line
run_test "dry-run has no side effects"          test_no_side_effects_no_archive_created
run_test "excluded subpath reported + netted"   test_excluded_subpath_reported_and_netted_from_total
run_test "excluded subpath reduces parent size" test_excluded_subpath_reduces_parent_size
run_test "missing exclude file is non-fatal"    test_missing_exclude_file_does_not_error
run_test "local include list is counted" test_local_list_is_counted

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

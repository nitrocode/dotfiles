#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/trufflehog-scan.sh.
# Mocks trufflehog (canned JSONL output) and python3 (writes deterministic
# tally + CSV) so the script's bash logic can be exercised without the real
# scanner or the sandbox's python3 path restrictions.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/trufflehog-scan.sh"
echo "test-trufflehog-scan.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/.claude/scripts/trufflehog" "$SANDBOX/bin" "$SANDBOX/target"
  CONFIG="$SANDBOX/.claude/scripts/trufflehog"
  : >"$CONFIG/exclude-paths.txt"
  : >"$CONFIG/allowlist.txt"
  : >"$CONFIG/placeholder-fp.txt"
  # default mocks: trufflehog with no findings, python3 writes empty tally
  install_mocks 0 0 0 0
  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"
  export HOME="$SANDBOX"
}

teardown_sandbox() {
  export HOME="$REAL_HOME"
  export PATH="$ORIG_PATH"
  rm -rf "$SANDBOX"
}

# install_mocks <unique> <verified> <high_unverified> <other_unverified>
install_mocks() {
  local unique="$1" verified="$2" high="$3" other="$4"
  cat >"$SANDBOX/bin/trufflehog" <<EOF
#!/bin/bash
if [ "\$1" = "--version" ]; then echo "trufflehog 3.0.0"; exit 0; fi
echo "trufflehog \$*" >>"$SANDBOX/trufflehog.calls"
# emit nothing → 0-finding scan
exit 0
EOF
  cat >"$SANDBOX/bin/python3" <<EOF
#!/bin/bash
# Mock python3 — the script's only python3 use is the heredoc that writes
# triage.csv + tally file. Emit deterministic values for assertions.
# Args after \`-\`: jsonl, allow, fp, csv, tally, fp_filter_flag
tally="\$6"  # 5th positional after the literal '-'
csv="\$5"
echo "detector,raw_prefix,raw_sha1_12,verified,high_signal,occurrences,sample_locations" >"\$csv"
printf "%s %s %s %s 0 0\n" "$unique" "$verified" "$high" "$other" >"\$tally"
exit 0
EOF
  chmod +x "$SANDBOX/bin/trufflehog" "$SANDBOX/bin/python3"
}

run_script() {
  bash "$SCRIPT" "$@"
}

# ---- tests ----

test_help_exits_zero() {
  setup_sandbox
  local out; out=$(run_script --help 2>&1)
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ] && assert_contains "$out" "trufflehog-scan.sh"
}

test_unknown_flag_exits_two() {
  setup_sandbox
  run_script "$SANDBOX/target" --not-a-real-flag >/dev/null 2>&1
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 2 ]
}

test_missing_trufflehog_exits_one() {
  setup_sandbox
  rm "$SANDBOX/bin/trufflehog"
  # Replace PATH entirely so the real /opt/homebrew/bin/trufflehog isn't picked up
  local err
  err=$(PATH="$SANDBOX/bin:/usr/bin:/bin" bash "$SCRIPT" "$SANDBOX/target" 2>&1 >/dev/null)
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 1 ] && assert_contains "$err" "trufflehog not found"
}

test_missing_exclude_file_exits_one() {
  setup_sandbox
  rm "$CONFIG/exclude-paths.txt"
  run_script "$SANDBOX/target" >/dev/null 2>&1
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 1 ]
}

test_include_git_strips_dotgit_from_effective_exclude() {
  setup_sandbox
  printf 'node_modules/\n\\.git/\nbuild/\n' >"$CONFIG/exclude-paths.txt"
  run_script "$SANDBOX/target" --include-git >/dev/null 2>&1
  local effective; effective=$(find "$CONFIG/runs" -name "exclude-paths.effective.txt" | head -1)
  local has_git=0
  grep -q '\.git/' "$effective" 2>/dev/null && has_git=1
  teardown_sandbox
  [ "$has_git" -eq 0 ]
}

test_effective_exclude_strips_comments_and_blanks() {
  setup_sandbox
  printf '# header comment\nnode_modules/\n\nbuild/  # trailing\n' >"$CONFIG/exclude-paths.txt"
  run_script "$SANDBOX/target" >/dev/null 2>&1
  local effective; effective=$(find "$CONFIG/runs" -name "exclude-paths.effective.txt" | head -1)
  local lines; lines=$(wc -l <"$effective" | tr -d ' ')
  local has_comment=0
  grep -q '^#' "$effective" 2>/dev/null && has_comment=1
  local has_blank=0
  grep -qE '^[[:space:]]*$' "$effective" 2>/dev/null && has_blank=1
  teardown_sandbox
  [ "$lines" = "2" ] && [ "$has_comment" -eq 0 ] && [ "$has_blank" -eq 0 ]
}

test_verified_only_passes_flag_to_trufflehog() {
  setup_sandbox
  run_script "$SANDBOX/target" --verified-only >/dev/null 2>&1
  local calls; calls=$(cat "$SANDBOX/trufflehog.calls" 2>/dev/null)
  teardown_sandbox
  assert_contains "$calls" "--only-verified"
}

test_verified_omitted_no_only_verified_flag() {
  setup_sandbox
  run_script "$SANDBOX/target" >/dev/null 2>&1
  local calls; calls=$(cat "$SANDBOX/trufflehog.calls" 2>/dev/null)
  teardown_sandbox
  case "$calls" in
    *"--only-verified"*) return 1;;
    *) return 0;;
  esac
}

test_meta_json_is_valid_and_has_fields() {
  setup_sandbox
  install_mocks 3 1 2 0
  run_script "$SANDBOX/target" >/dev/null 2>&1
  local meta; meta=$(find "$CONFIG/runs" -name meta.json | head -1)
  local unique verified
  unique=$(jq -r '.unique_findings' "$meta")
  verified=$(jq -r '.unique_verified' "$meta")
  teardown_sandbox
  [ "$unique" = "3" ] && [ "$verified" = "1" ]
}

test_fail_on_verified_exits_two_when_verified_present() {
  setup_sandbox
  install_mocks 1 1 0 0
  run_script "$SANDBOX/target" --fail-on-verified >/dev/null 2>&1
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 2 ]
}

test_fail_on_verified_exits_zero_when_clean() {
  setup_sandbox
  install_mocks 0 0 0 0
  run_script "$SANDBOX/target" --fail-on-verified >/dev/null 2>&1
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ]
}

test_triage_csv_is_created() {
  setup_sandbox
  run_script "$SANDBOX/target" >/dev/null 2>&1
  local csv exists=0
  csv=$(find "$CONFIG/runs" -name triage.csv | head -1)
  [ -f "$csv" ] && exists=1
  teardown_sandbox
  [ "$exists" -eq 1 ]
}

test_legacy_all_flag_is_accepted() {
  setup_sandbox
  run_script "$SANDBOX/target" --all >/dev/null 2>&1
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ]
}

run_test "--help → exit 0 with usage"                test_help_exits_zero
run_test "unknown flag → exit 2"                     test_unknown_flag_exits_two
run_test "missing trufflehog binary → exit 1"        test_missing_trufflehog_exits_one
run_test "missing exclude file → exit 1"             test_missing_exclude_file_exits_one
run_test "--include-git removes .git/ from exclude"  test_include_git_strips_dotgit_from_effective_exclude
run_test "comments + blanks stripped from exclude"   test_effective_exclude_strips_comments_and_blanks
run_test "--verified-only → --only-verified passed"  test_verified_only_passes_flag_to_trufflehog
run_test "no --verified-only → no --only-verified"   test_verified_omitted_no_only_verified_flag
run_test "meta.json valid + has expected fields"     test_meta_json_is_valid_and_has_fields
run_test "--fail-on-verified + verified → exit 2"    test_fail_on_verified_exits_two_when_verified_present
run_test "--fail-on-verified + clean → exit 0"       test_fail_on_verified_exits_zero_when_clean
run_test "triage.csv is created"                     test_triage_csv_is_created
run_test "legacy --all flag is silently accepted"    test_legacy_all_flag_is_accepted

print_summary

#!/usr/bin/env bash
# Unit tests for upload-csv-to-drive.sh. Mocks `rclone` via a PATH shim so no
# real Google Drive or ~/.config/rclone/rclone.conf call happens. The fake
# rclone reads/writes a JSON file to simulate Drive state across
# lsjson/copy/deletefile calls within a single test run.
#
# Run: bash $CLAUDE_CONFIG_DIR/scripts/tests/test-upload-csv-to-drive.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/../upload-csv-to-drive.sh"

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc} (expected to contain: ${needle})"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" desc="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${desc} (expected NOT to contain: ${needle})"
  fi
}

setup_sandbox() {
  local sandbox
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin"
  echo "$sandbox"
}

# Writes fake `rclone` binary into "$1/bin". Fake rclone:
#   - lsjson REMOTE           -> prints contents of $DRIVE_STATE (JSON array)
#   - copy SRC REMOTE ...     -> appends {"Name": <basename of SRC>} to
#                                 $DRIVE_STATE and logs the full argv to
#                                 $RCLONE_COPY_LOG
#   - deletefile REMOTE/NAME  -> removes matching Name from $DRIVE_STATE and
#                                 logs the call to $RCLONE_DELETE_LOG
# Requires real `jq` on PATH to manipulate $DRIVE_STATE (jq itself is not
# mocked; it's a read-only json transform, safe to use for real in tests).
write_fake_rclone() {
  local bin_dir="$1"
  cat >"${bin_dir}/rclone" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  lsjson)
    cat "$DRIVE_STATE"
    ;;
  copy)
    src="$1"
    echo "copy $*" >>"$RCLONE_COPY_LOG"
    name="$(basename "$src")"
    tmp="$(mktemp)"
    jq --arg n "$name" '. + [{"Name": $n}]' "$DRIVE_STATE" >"$tmp"
    mv "$tmp" "$DRIVE_STATE"
    ;;
  deletefile)
    target="$1"
    echo "deletefile $*" >>"$RCLONE_DELETE_LOG"
    fname="$(basename "$target")"
    tmp="$(mktemp)"
    jq --arg n "$fname" '[.[] | select(.Name != $n)]' "$DRIVE_STATE" >"$tmp"
    mv "$tmp" "$DRIVE_STATE"
    ;;
  *)
    echo "unmocked rclone command: $cmd" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${bin_dir}/rclone"
}

# Force-fails `rclone copy` for one specific staged filename substring,
# everything else behaves like write_fake_rclone.
write_fake_rclone_failing_copy_for() {
  local bin_dir="$1" fail_match="$2"
  cat >"${bin_dir}/rclone" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cmd="\$1"; shift
case "\$cmd" in
  lsjson)
    cat "\$DRIVE_STATE"
    ;;
  copy)
    src="\$1"
    echo "copy \$*" >>"\$RCLONE_COPY_LOG"
    name="\$(basename "\$src")"
    case "\$name" in
      *"${fail_match}"*)
        echo "simulated copy failure for \$name" >&2
        exit 1
        ;;
    esac
    tmp="\$(mktemp)"
    jq --arg n "\$name" '. + [{"Name": \$n}]' "\$DRIVE_STATE" >"\$tmp"
    mv "\$tmp" "\$DRIVE_STATE"
    ;;
  deletefile)
    target="\$1"
    echo "deletefile \$*" >>"\$RCLONE_DELETE_LOG"
    fname="\$(basename "\$target")"
    tmp="\$(mktemp)"
    jq --arg n "\$fname" '[.[] | select(.Name != \$n)]' "\$DRIVE_STATE" >"\$tmp"
    mv "\$tmp" "\$DRIVE_STATE"
    ;;
  *)
    echo "unmocked rclone command: \$cmd" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${bin_dir}/rclone"
}

make_csv() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  printf 'a,b,c\n1,2,3\n' >"${dir}/${name}.csv"
}

# --- Test 1: single-file upload, title derived from filename ---------------
test_single_file_upload() {
  local sandbox src_file
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "report"
  src_file="${sandbox}/src/report.csv"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$src_file" "Test Folder" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "single file: script exits 0"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'report'" "single file: title derived from filename"
  assert_contains "$(cat "${sandbox}/copy.log")" "report.csv" "single file: staged filename matches derived title"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 0, failed 0" "single file: summary reflects 1 upload"

  rm -rf "$sandbox"
}

# --- Test 2: directory of multiple CSVs, non-recursive ---------------------
test_directory_non_recursive() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "alpha"
  make_csv "${sandbox}/src" "beta"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'alpha'" "dir non-recursive: alpha uploaded with filename-derived title"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'beta'" "dir non-recursive: beta uploaded with filename-derived title"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 2, skipped 0, failed 0" "dir non-recursive: summary reflects 2 uploads"

  rm -rf "$sandbox"
}

# --- Test 3: --recursive finds nested files, without it they're skipped ----
test_recursive_flag() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src/nested" "gamma"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" >"${sandbox}/run_norecurse.log" 2>&1

  assert_contains "$(cat "${sandbox}/run_norecurse.log")" "Found 0 CSV file(s)" "recursive: without --recursive, nested file not found"

  echo '[]' >"${sandbox}/drive_state.json"
  rm -f "${sandbox}/copy.log"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" --recursive >"${sandbox}/run_recurse.log" 2>&1

  assert_contains "$(cat "${sandbox}/run_recurse.log")" "Found 1 CSV file(s)" "recursive: --recursive finds nested file"
  assert_contains "$(cat "${sandbox}/run_recurse.log")" "uploaded as 'gamma'" "recursive: nested file uploaded"

  rm -rf "$sandbox"
}

# --- Test 4: --title-prefix applied to all derived titles ------------------
test_title_prefix() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "alpha"
  make_csv "${sandbox}/src" "beta"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" --title-prefix "Report - " >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'Report - alpha'" "title-prefix: applied to alpha"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'Report - beta'" "title-prefix: applied to beta"
  assert_contains "$(cat "${sandbox}/copy.log")" "Report - alpha.csv" "title-prefix: staged filename carries prefix"

  rm -rf "$sandbox"
}

# --- Test 5: --title on single file works; on directory it's a hard error -
test_title_override() {
  local sandbox src_file
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "report"
  src_file="${sandbox}/src/report.csv"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$src_file" "Test Folder" --title "Custom Title" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "title override: single-file exits 0"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded as 'Custom Title'" "title override: single-file uses explicit title"

  echo '[]' >"${sandbox}/drive_state.json"
  rm -f "${sandbox}/copy.log"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" --title "Custom Title" >"${sandbox}/run_dir.log" 2>&1
  local dir_exit_code=$?

  assert_eq "$([[ "$dir_exit_code" -ne 0 ]] && echo "nonzero" || echo "zero")" "nonzero" "title override: directory source is a hard error"
  assert_eq "$([[ -f "${sandbox}/copy.log" ]] && echo yes || echo no)" "no" "title override: directory error attempts no uploads"

  rm -rf "$sandbox"
}

# --- Test 6: idempotency, existing file with virtual .xlsx extension -------
test_skips_existing_with_virtual_extension() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "alpha"
  make_csv "${sandbox}/src" "beta"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "alpha.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/run.log")" "alpha: skipped-exists" "idempotency: virtual .xlsx extension matched and skipped"
  assert_not_contains "$([[ -f "${sandbox}/copy.log" ]] && cat "${sandbox}/copy.log" || true)" "alpha.csv" "idempotency: skipped file never passed to rclone copy"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 1, failed 0" "idempotency: summary shows 1 uploaded 1 skipped"

  rm -rf "$sandbox"
}

# --- Test 7: --overwrite deletes existing (actual name) then re-uploads ----
test_overwrite_deletes_then_reuploads() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "alpha"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "alpha.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" --overwrite >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/delete.log")" "alpha.xlsx" "overwrite: deletefile called with actual returned name"
  assert_contains "$(cat "${sandbox}/copy.log")" "alpha.csv" "overwrite: re-uploaded after delete"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 0, failed 0" "overwrite: summary shows 1 uploaded"

  rm -rf "$sandbox"
}

# --- Test 8: --dry-run makes no copy/deletefile calls -----------------------
test_dry_run_no_side_effects() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "alpha"
  make_csv "${sandbox}/src" "existing"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "existing.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" --overwrite --dry-run >"${sandbox}/run.log" 2>&1

  assert_eq "$([[ -f "${sandbox}/copy.log" ]] && echo yes || echo no)" "no" "dry-run: rclone copy never invoked"
  assert_eq "$([[ -f "${sandbox}/delete.log" ]] && echo yes || echo no)" "no" "dry-run: rclone deletefile never invoked"
  assert_contains "$(cat "${sandbox}/run.log")" "[dry-run] would upload as 'alpha'" "dry-run: prints intended upload for new file"
  assert_contains "$(cat "${sandbox}/run.log")" "[dry-run] would delete 'existing.xlsx' then re-upload" "dry-run: prints intended delete+reupload for existing file with --overwrite"

  rm -rf "$sandbox"
}

# --- Test 9: one file's upload fails, batch continues, failure counted -----
test_partial_failure_continues() {
  local sandbox
  sandbox="$(setup_sandbox)"
  make_csv "${sandbox}/src" "broken"
  make_csv "${sandbox}/src" "good"

  write_fake_rclone_failing_copy_for "${sandbox}/bin" "broken"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "${sandbox}/src" "Test Folder" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "partial failure: script still exits 0 (batch continues, set -uo pipefail not -e)"
  assert_contains "$(cat "${sandbox}/run.log")" "broken: failed" "partial failure: broken file logged as failed"
  assert_contains "$(cat "${sandbox}/run.log")" "good: uploaded" "partial failure: good file still uploaded"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 0, failed 1" "partial failure: summary reflects 1 uploaded 1 failed"

  rm -rf "$sandbox"
}

test_single_file_upload
test_directory_non_recursive
test_recursive_flag
test_title_prefix
test_title_override
test_skips_existing_with_virtual_extension
test_overwrite_deletes_then_reuploads
test_dry_run_no_side_effects
test_partial_failure_continues

echo ""
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# Unit tests for upload-entitlements-to-drive.sh. The generic upload logic
# (idempotency, --overwrite, --dry-run, rclone flags) already has full
# coverage in test-upload-csv-to-drive.sh, so this suite mocks `rclone`
# (the same fake shim, since the wrapper delegates to the real
# upload-csv-to-drive.sh as a subprocess) and focuses on proving the
# wrapper correctly translates the <dir>/<profile>/s3-entitlements-<profile>.csv
# layout into calls to the generic tool, plus preserves per-account
# failure-doesn't-abort-batch behavior.
#
# Run: bash $CLAUDE_CONFIG_DIR/scripts/tests/test-upload-entitlements-to-drive.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/../upload-entitlements-to-drive.sh"

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

# Same fake rclone shim used by test-upload-csv-to-drive.sh: the wrapper
# delegates to the real, unmocked upload-csv-to-drive.sh, which is the thing
# that actually calls rclone.
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

# Force-fails `rclone copy` for one specific account name (matched against
# the staged filename), everything else behaves like write_fake_rclone.
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

make_account_csv() {
  local local_dir="$1" profile="$2"
  mkdir -p "${local_dir}/${profile}"
  printf 'account,principal_type,principal_name\n%s,user,test-user\n' "$profile" \
    >"${local_dir}/${profile}/s3-entitlements-${profile}.csv"
}

# --- Test 1: happy path, two accounts, neither exists yet -------------------
test_happy_path() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  make_account_csv "$local_dir" "secops-ads-dev"
  make_account_csv "$local_dir" "secops-ads-prod"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "happy path: script exits 0"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 2, skipped 0, failed 0" "happy path: summary reflects 2 uploads (delegated)"
  assert_contains "$(cat "${sandbox}/copy.log")" "S3 Entitlements - secops-ads-dev.csv" "happy path: staged filename has clean title + .csv for dev"
  assert_contains "$(cat "${sandbox}/copy.log")" "S3 Entitlements - secops-ads-prod.csv" "happy path: staged filename has clean title + .csv for prod"
  assert_contains "$(cat "${sandbox}/copy.log")" "--drive-import-formats csv" "happy path: generic script's import-formats flag present"
  assert_contains "$(cat "${sandbox}/copy.log")" "--drive-export-formats csv,xlsx" "happy path: generic script's export-formats flag present"
  assert_contains "$(cat "${sandbox}/copy.log")" "--drive-allow-import-name-change" "happy path: generic script's allow-import-name-change flag present"

  rm -rf "$sandbox"
}

# --- Test 2: idempotency, one account already exists -> skipped -------------
# (Delegated to upload-csv-to-drive.sh; this proves the wrapper's naming
# convention lines up with what the generic script checks against.)
test_skips_existing() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  make_account_csv "$local_dir" "secops-ads-dev"
  make_account_csv "$local_dir" "secops-ads-prod"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "S3 Entitlements - secops-ads-dev.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/run.log")" "secops-ads-dev: skipped-exists" "idempotency: existing account skipped"
  assert_not_contains "$([[ -f "${sandbox}/copy.log" ]] && cat "${sandbox}/copy.log" || true)" "secops-ads-dev" "idempotency: skipped account never passed to rclone copy"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 1, failed 0" "idempotency: summary shows 1 uploaded 1 skipped"

  rm -rf "$sandbox"
}

# --- Test 3: --overwrite deletes existing then re-uploads -------------------
test_overwrite_deletes_then_reuploads() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  make_account_csv "$local_dir" "secops-ads-dev"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "S3 Entitlements - secops-ads-dev.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" --overwrite >"${sandbox}/run.log" 2>&1

  assert_contains "$(cat "${sandbox}/delete.log")" "S3 Entitlements - secops-ads-dev" "overwrite: deletefile called for existing name"
  assert_contains "$(cat "${sandbox}/copy.log")" "S3 Entitlements - secops-ads-dev.csv" "overwrite: re-uploaded after delete"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 0, failed 0" "overwrite: summary shows 1 uploaded"

  rm -rf "$sandbox"
}

# --- Test 4: --dry-run makes no copy/deletefile calls ------------------------
test_dry_run_no_side_effects() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  make_account_csv "$local_dir" "secops-ads-dev"
  make_account_csv "$local_dir" "secops-ads-existing"

  write_fake_rclone "${sandbox}/bin"
  echo '[{"Name": "S3 Entitlements - secops-ads-existing.xlsx"}]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" --overwrite --dry-run >"${sandbox}/run.log" 2>&1

  assert_eq "$([[ -f "${sandbox}/copy.log" ]] && echo yes || echo no)" "no" "dry-run: rclone copy never invoked"
  assert_eq "$([[ -f "${sandbox}/delete.log" ]] && echo yes || echo no)" "no" "dry-run: rclone deletefile never invoked"
  assert_contains "$(cat "${sandbox}/run.log")" "[dry-run] would upload as 'S3 Entitlements - secops-ads-dev'" "dry-run: prints intended upload for new account"
  assert_contains "$(cat "${sandbox}/run.log")" "[dry-run] would delete 'S3 Entitlements - secops-ads-existing.xlsx' then re-upload" "dry-run: prints intended delete+reupload for existing account with --overwrite"

  rm -rf "$sandbox"
}

# --- Test 5: one account's copy fails, batch continues, failure counted ----
test_partial_failure_continues() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  make_account_csv "$local_dir" "secops-broken"
  make_account_csv "$local_dir" "secops-good"

  write_fake_rclone_failing_copy_for "${sandbox}/bin" "secops-broken"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "partial failure: script still exits 0 (batch continues, set -uo pipefail not -e)"
  assert_contains "$(cat "${sandbox}/run.log")" "secops-broken: failed" "partial failure: broken account logged as failed"
  assert_contains "$(cat "${sandbox}/run.log")" "secops-good: uploaded" "partial failure: good account still uploaded"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 1, skipped 0, failed 1" "partial failure: summary reflects 1 uploaded 1 failed"

  rm -rf "$sandbox"
}

# --- Test 6: wrapper's own layout translation, no accounts found ----------
test_no_accounts_found() {
  local sandbox local_dir
  sandbox="$(setup_sandbox)"
  local_dir="${sandbox}/accounts"
  mkdir -p "$local_dir"

  write_fake_rclone "${sandbox}/bin"
  echo '[]' >"${sandbox}/drive_state.json"

  PATH="${sandbox}/bin:$PATH" \
    DRIVE_STATE="${sandbox}/drive_state.json" \
    RCLONE_COPY_LOG="${sandbox}/copy.log" \
    RCLONE_DELETE_LOG="${sandbox}/delete.log" \
    bash "$TARGET" "$local_dir" "Test Folder" >"${sandbox}/run.log" 2>&1
  local exit_code=$?

  assert_eq "$exit_code" "0" "no accounts: exits 0"
  assert_contains "$(cat "${sandbox}/run.log")" "Found 0 account CSVs" "no accounts: wrapper reports 0 found from its own layout scan"
  assert_contains "$(cat "${sandbox}/run.log")" "uploaded 0, skipped 0, failed 0" "no accounts: summary all zero, no delegation attempted"
  assert_eq "$([[ -f "${sandbox}/copy.log" ]] && echo yes || echo no)" "no" "no accounts: rclone copy never invoked"

  rm -rf "$sandbox"
}

test_happy_path
test_skips_existing
test_overwrite_deletes_then_reuploads
test_dry_run_no_side_effects
test_partial_failure_continues
test_no_accounts_found

echo ""
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]

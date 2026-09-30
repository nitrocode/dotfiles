#!/usr/bin/env bash
# Tests for macos-defaults-import.sh. Mocks `defaults` via a PATH shim.
# Critically verifies dry-run (no --apply) never calls `defaults import`.

set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/macos-defaults-import.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

GREEN='\033[32m'; RED='\033[31m'; RESET='\033[0m'
PASS=0; FAIL=0

run_test() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1)); printf "  ${GREEN}✓${RESET} %s\n" "$name"
  else
    FAIL=$((FAIL + 1)); printf "  ${RED}✗${RESET} %s\n" "$name"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) printf '    expected to contain: %s\n    got: %s\n' "$2" "$(printf '%s' "$1" | head -c 400)" >&2; return 1 ;;
  esac
}

setup_backup_dir_and_fake_defaults() {
  mkdir -p "$SANDBOX/bin" "$SANDBOX/backup"
  echo "fake" > "$SANDBOX/backup/dock.plist"
  echo "fake" > "$SANDBOX/backup/finder.plist"
  # marker file: fake `defaults` touches this only when actually invoked with "import"
  rm -f "$SANDBOX/import_calls.log"
  cat > "$SANDBOX/bin/defaults" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "import" ]; then
  echo "\$2 \$3" >> "$SANDBOX/import_calls.log"
  exit 0
fi
exit 1
EOF
  chmod +x "$SANDBOX/bin/defaults"
}

test_dry_run_by_default_calls_defaults_zero_times() {
  setup_backup_dir_and_fake_defaults
  local out
  out="$(PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$SANDBOX/backup")"
  assert_contains "$out" "Dry-run only, nothing was changed" && [ ! -f "$SANDBOX/import_calls.log" ]
}

test_apply_flag_actually_calls_defaults_import() {
  setup_backup_dir_and_fake_defaults
  PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$SANDBOX/backup" --apply >/dev/null
  [ -f "$SANDBOX/import_calls.log" ] && \
  grep -q "com.apple.dock" "$SANDBOX/import_calls.log" && \
  grep -q "com.apple.finder" "$SANDBOX/import_calls.log"
}

test_reports_missing_files_from_backup() {
  setup_backup_dir_and_fake_defaults
  rm "$SANDBOX/backup/finder.plist"
  local out
  out="$(PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$SANDBOX/backup")"
  assert_contains "$out" "missing: finder.plist"
}

test_missing_backup_dir_errors_nonzero() {
  bash "$SCRIPT" "$SANDBOX/no-such-dir" >/tmp/out.$$ 2>/tmp/err.$$
  local status=$?
  local err
  err="$(cat /tmp/err.$$)"
  rm -f "/tmp/out.$$" "/tmp/err.$$"
  [ "$status" -ne 0 ] && assert_contains "$err" "not found"
}

echo "Running macos-defaults-import.sh tests..."
run_test "dry-run by default never calls defaults import"  test_dry_run_by_default_calls_defaults_zero_times
run_test "--apply actually calls defaults import"          test_apply_flag_actually_calls_defaults_import
run_test "reports files missing from backup"               test_reports_missing_files_from_backup
run_test "missing backup dir errors non-zero"               test_missing_backup_dir_errors_nonzero

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

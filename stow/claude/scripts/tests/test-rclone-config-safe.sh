#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/rclone-config-safe.sh.
# Mocks `rclone` via a PATH shim so no real Drive/API call happens.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/rclone-config-safe.sh"
echo "test-rclone-config-safe.sh:"

setup_bin() {
  BINDIR=$(mktemp -d)
  export PATH="$BINDIR:$PATH"
}

teardown_bin() {
  rm -rf "$BINDIR"
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*)
      printf '    expected NOT to contain %s\n    in: %s\n' "$needle" "$(printf '%s' "$haystack" | head -c 200)" >&2
      return 1
      ;;
    *) return 0;;
  esac
}

write_rclone_stub_success() {
  cat > "$BINDIR/rclone" <<'EOF'
#!/bin/bash
if [ "$1" = "config" ]; then
  echo "[gdrive]"
  echo "type = drive"
  echo 'token = {"access_token":"ya29.SUPERSECRETACCESSTOKEN","refresh_token":"1//SUPERSECRETREFRESH"}'
  echo "scope = drive"
  echo "client_id = 926508089652-abc.apps.googleusercontent.com"
  echo "client_secret = GOCSPX-SUPERSECRETCLIENTSECRET"
  echo "team_drive = "
  exit 0
fi
exit 1
EOF
  chmod +x "$BINDIR/rclone"
}

write_rclone_stub_failure() {
  cat > "$BINDIR/rclone" <<'EOF'
#!/bin/bash
if [ "$1" = "config" ]; then
  echo "some notice" >&2
  echo "client_secret = GOCSPX-LEAKEDONFAILUREPATH" >&2
  exit 3
fi
exit 1
EOF
  chmod +x "$BINDIR/rclone"
}

test_success_redacts_stdout() {
  setup_bin
  write_rclone_stub_success
  out=$(bash "$SCRIPT" update gdrive client_id X client_secret Y 2>/dev/null)
  teardown_bin
  assert_not_contains "$out" "SUPERSECRETACCESSTOKEN" \
    && assert_not_contains "$out" "SUPERSECRETREFRESH" \
    && assert_not_contains "$out" "GOCSPX-SUPERSECRETCLIENTSECRET" \
    && assert_contains "$out" "[REDACTED]" \
    && assert_contains "$out" "succeeded"
}

test_success_preserves_nonsecret_fields() {
  setup_bin
  write_rclone_stub_success
  out=$(bash "$SCRIPT" update gdrive client_id X client_secret Y 2>/dev/null)
  teardown_bin
  assert_contains "$out" "client_id = 926508089652-abc.apps.googleusercontent.com" \
    && assert_contains "$out" "type = drive"
}

test_success_exit_code_zero() {
  setup_bin
  write_rclone_stub_success
  bash "$SCRIPT" update gdrive client_id X client_secret Y >/dev/null 2>/dev/null
  code=$?
  teardown_bin
  [ "$code" -eq 0 ]
}

test_failure_redacts_stderr_and_propagates_exit() {
  setup_bin
  write_rclone_stub_failure
  err=$(bash "$SCRIPT" update gdrive client_id X client_secret Y 2>&1 1>/dev/null)
  code=$?
  teardown_bin
  assert_not_contains "$err" "LEAKEDONFAILUREPATH" \
    && assert_contains "$err" "FAILED" \
    && [ "$code" -eq 3 ]
}

test_missing_args_usage_error() {
  err=$(bash "$SCRIPT" 2>&1 1>/dev/null)
  code=$?
  assert_contains "$err" "usage:" && [ "$code" -eq 2 ]
}

run_test "success redacts secrets from stdout" test_success_redacts_stdout
run_test "success preserves non-secret fields" test_success_preserves_nonsecret_fields
run_test "success propagates exit code 0" test_success_exit_code_zero
run_test "failure redacts secrets from stderr and propagates exit code" test_failure_redacts_stderr_and_propagates_exit
run_test "missing args prints usage and exits 2" test_missing_args_usage_error

print_summary

#!/usr/bin/env bash
# Tests for laptop-migration-unpack.sh. Mocks brew/crontab/launchctl via a
# PATH shim so --apply-configs never touches the real system.

set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/laptop-migration-unpack.sh"
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

setup_fixture() {
  rm -rf "$SANDBOX/home" "$SANDBOX/src" "$SANDBOX/bin"
  mkdir -p "$SANDBOX/home" "$SANDBOX/src" "$SANDBOX/bin"

  # build a real small archive to unpack: one dotfile, one dir
  local build="$SANDBOX/build"
  rm -rf "$build"; mkdir -p "$build/present_dir"
  echo "content" > "$build/.zshrc"
  echo "content2" > "$build/present_dir/file.txt"
  echo "fakebrewfile" > "$build/Brewfile"
  echo "* * * * * fake job" > "$build/crontab.backup.txt"

  tar -czf "$SANDBOX/src/laptop-migration-20260101-000000.tar.gz" -C "$build" .
  shasum -a 256 "$SANDBOX/src/laptop-migration-20260101-000000.tar.gz" | awk '{print $1}' \
    > "$SANDBOX/src/laptop-migration-20260101-000000.tar.gz.sha256"

  cat > "$SANDBOX/bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$LOGDIR/calls.log"
exit 0
EOF
  cat > "$SANDBOX/bin/crontab" <<'EOF'
#!/usr/bin/env bash
echo "crontab $*" >> "$LOGDIR/calls.log"
exit 0
EOF
  cat > "$SANDBOX/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "launchctl $*" >> "$LOGDIR/calls.log"
exit 0
EOF
  chmod +x "$SANDBOX/bin/brew" "$SANDBOX/bin/crontab" "$SANDBOX/bin/launchctl"
  rm -f "$SANDBOX/calls.log"
}

run_unpack() {
  LOGDIR="$SANDBOX" HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$SANDBOX/src" "$@"
}

test_dry_run_default_extracts_nothing() {
  setup_fixture
  local out
  out="$(run_unpack)"
  assert_contains "$out" "[dry-run]" && [ ! -f "$SANDBOX/home/.zshrc" ]
}

test_extract_flag_writes_files() {
  setup_fixture
  run_unpack --extract >/dev/null
  [ -f "$SANDBOX/home/.zshrc" ] && [ -f "$SANDBOX/home/present_dir/file.txt" ]
}

test_checksum_mismatch_aborts_without_extracting() {
  setup_fixture
  echo "deadbeef" > "$SANDBOX/src/laptop-migration-20260101-000000.tar.gz.sha256"
  run_unpack --extract >/tmp/out.$$ 2>/tmp/err.$$
  local status=$?
  local err
  err="$(cat /tmp/err.$$)"
  rm -f "/tmp/out.$$" "/tmp/err.$$"
  [ "$status" -ne 0 ] && assert_contains "$err" "checksum mismatch" && [ ! -f "$SANDBOX/home/.zshrc" ]
}

test_missing_archive_errors_nonzero() {
  setup_fixture
  rm -f "$SANDBOX/src"/*.tar.gz "$SANDBOX/src"/*.sha256
  run_unpack >/tmp/out.$$ 2>/tmp/err.$$
  local status=$?
  rm -f "/tmp/out.$$" "/tmp/err.$$"
  [ "$status" -ne 0 ]
}

test_apply_configs_invokes_brew_crontab_launchctl() {
  setup_fixture
  run_unpack --apply-configs >/dev/null
  local log
  log="$(cat "$SANDBOX/calls.log" 2>/dev/null || echo "")"
  assert_contains "$log" "brew bundle install" && assert_contains "$log" "crontab"
}

test_extract_without_apply_configs_does_not_call_brew() {
  setup_fixture
  run_unpack --extract >/dev/null
  [ ! -f "$SANDBOX/calls.log" ]
}

echo "Running laptop-migration-unpack.sh tests..."
run_test "dry-run by default extracts nothing"            test_dry_run_default_extracts_nothing
run_test "--extract writes files"                          test_extract_flag_writes_files
run_test "checksum mismatch aborts, no extraction"          test_checksum_mismatch_aborts_without_extracting
run_test "missing archive errors non-zero"                  test_missing_archive_errors_nonzero
run_test "--apply-configs invokes brew/crontab/launchctl"    test_apply_configs_invokes_brew_crontab_launchctl
run_test "--extract alone never touches brew/crontab"        test_extract_without_apply_configs_does_not_call_brew

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

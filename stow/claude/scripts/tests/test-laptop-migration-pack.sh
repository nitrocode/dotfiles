#!/usr/bin/env bash
# Tests for laptop-migration-pack.sh. Runs entirely inside a mktemp sandbox
# with a sandboxed HOME and a fixture include list; mocks brew/crontab/code/
# cursor/defaults via a PATH shim so nothing on the real machine is touched.

set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/laptop-migration-pack.sh"
REAL_MACOS_EXPORT_SCRIPT=$CLAUDE_CONFIG_DIR/scripts/macos-defaults-export.sh"
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
  rm -rf "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/list.txt" "$SANDBOX/exclude.txt"
  mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/home/.claude/scripts"
  echo "some dotfile content" > "$SANDBOX/home/.zshrc"
  mkdir -p "$SANDBOX/home/present_dir"
  echo "hi" > "$SANDBOX/home/present_dir/file.txt"
  mkdir -p "$SANDBOX/home/present_dir/cache"
  echo "reproducible junk" > "$SANDBOX/home/present_dir/cache/blob.bin"

  cat > "$SANDBOX/list.txt" <<EOF
~/.zshrc
~/present_dir
~/does_not_exist
EOF

  cat > "$SANDBOX/exclude.txt" <<EOF
# reproducible cache, should be excluded from the archive
~/present_dir/cache
EOF

  # copy the real macos-defaults-export.sh in so the pack script's call to
  # "\$SCRIPT_DIR/macos-defaults-export.sh" resolves; SCRIPT_DIR is derived
  # from the real script's own location, not the sandbox, so we symlink the
  # sandboxed HOME's expected script path to the real one for this test.
  cp "$REAL_MACOS_EXPORT_SCRIPT" "$SANDBOX/home/.claude/scripts/" 2>/dev/null || true

  # fake external commands
  cat > "$SANDBOX/bin/brew" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "bundle" ] && [ "$2" = "dump" ]; then
  for a in "$@"; do case "$a" in --file=*) f="${a#--file=}";; esac; done
  echo "fake brewfile" > "$f"
  exit 0
fi
exit 0
EOF
  cat > "$SANDBOX/bin/crontab" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-l" ]; then echo "* * * * * fake job"; exit 0; fi
exit 0
EOF
  cat > "$SANDBOX/bin/defaults" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "export" ]; then
  case "$2" in
    com.apple.dock) echo fake > "$3"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 1
EOF
  chmod +x "$SANDBOX/bin/brew" "$SANDBOX/bin/crontab" "$SANDBOX/bin/defaults"
}

run_pack() {
  HOME="$SANDBOX/home" \
  PATH="$SANDBOX/bin:$PATH" \
  LAPTOP_MIGRATION_LIST_FILE="$SANDBOX/list.txt" \
  LAPTOP_MIGRATION_EXCLUDE_FILE="${LAPTOP_MIGRATION_EXCLUDE_FILE_OVERRIDE:-$SANDBOX/exclude.txt}" \
  bash "$SCRIPT" "$SANDBOX/dest"
}

test_creates_archive_and_checksum() {
  setup_fixture
  local out
  out="$(run_pack)"
  local archive
  archive="$(find "$SANDBOX/dest" -name 'laptop-migration-*.tar.gz' | head -1)"
  [ -n "$archive" ] && [ -f "$archive.sha256" ] && assert_contains "$out" "Archive:"
}

test_archive_contains_expected_files_not_missing_one() {
  setup_fixture
  run_pack >/dev/null
  local archive
  archive="$(find "$SANDBOX/dest" -name 'laptop-migration-*.tar.gz' | head -1)"
  local listing
  listing="$(tar -tzf "$archive")"
  assert_contains "$listing" ".zshrc" && \
  assert_contains "$listing" "present_dir/file.txt" && \
  if printf '%s' "$listing" | grep -q "does_not_exist"; then return 1; fi
  return 0
}

test_archive_excludes_listed_subpath() {
  setup_fixture
  run_pack >/dev/null
  local archive
  archive="$(find "$SANDBOX/dest" -name 'laptop-migration-*.tar.gz' | head -1)"
  local listing
  listing="$(tar -tzf "$archive")"
  # present_dir itself is included, but its cache/ subdir is excluded
  assert_contains "$listing" "present_dir/file.txt" || return 1
  if printf '%s' "$listing" | grep -q "present_dir/cache"; then return 1; fi
  return 0
}

test_reports_excluded_count() {
  setup_fixture
  local out
  out="$(run_pack)"
  assert_contains "$out" "Excluded paths (reproducible cache/build output, not archived): 1"
}

test_missing_exclude_file_does_not_error() {
  setup_fixture
  local out status
  out="$(LAPTOP_MIGRATION_EXCLUDE_FILE_OVERRIDE="$SANDBOX/no-such-exclude.txt" run_pack)"
  status=$?
  assert_contains "$out" "Excluded paths (reproducible cache/build output, not archived): 0" && [ "$status" -eq 0 ]
}

test_reports_missing_count() {
  setup_fixture
  local out
  out="$(run_pack)"
  assert_contains "$out" "Missing paths skipped: 1"
}

test_checksum_matches_archive() {
  setup_fixture
  run_pack >/dev/null
  local archive
  archive="$(find "$SANDBOX/dest" -name 'laptop-migration-*.tar.gz' | head -1)"
  local expected actual
  expected="$(cat "$archive.sha256")"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [ "$expected" = "$actual" ]
}

test_missing_list_file_errors_nonzero() {
  setup_fixture
  HOME="$SANDBOX/home" PATH="$SANDBOX/bin:$PATH" LAPTOP_MIGRATION_LIST_FILE="$SANDBOX/no-such-list.txt" \
    bash "$SCRIPT" "$SANDBOX/dest" >/tmp/out.$$ 2>/tmp/err.$$
  local status=$?
  local err
  err="$(cat /tmp/err.$$)"
  rm -f "/tmp/out.$$" "/tmp/err.$$"
  [ "$status" -ne 0 ] && assert_contains "$err" "not readable"
}

echo "Running laptop-migration-pack.sh tests..."
run_test "creates archive and checksum file"          test_creates_archive_and_checksum
run_test "archive has present paths, skips missing"   test_archive_contains_expected_files_not_missing_one
run_test "archive excludes listed subpath"            test_archive_excludes_listed_subpath
run_test "reports excluded-path count"                test_reports_excluded_count
run_test "missing exclude file is non-fatal"          test_missing_exclude_file_does_not_error
run_test "reports missing-path count"                 test_reports_missing_count
run_test "checksum matches archive contents"           test_checksum_matches_archive
run_test "missing include list errors non-zero"        test_missing_list_file_errors_nonzero

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

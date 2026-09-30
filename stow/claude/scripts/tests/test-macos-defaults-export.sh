#!/usr/bin/env bash
# Tests for macos-defaults-export.sh. Mocks `defaults` via a PATH shim so no
# real macOS defaults database is touched.

set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/macos-defaults-export.sh"
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

# fake `defaults` binary: succeeds for known-good domains, fails for others,
# writes a marker file so we can assert it never mutates anything itself.
setup_fake_defaults() {
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/defaults" <<'EOF'
#!/usr/bin/env bash
# fake `defaults` for testing: only supports `export <domain> <file>`
if [ "$1" = "export" ]; then
  domain="$2"; file="$3"
  case "$domain" in
    com.apple.dock|com.apple.finder) echo "fake plist for $domain" > "$file"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 1
EOF
  chmod +x "$SANDBOX/bin/defaults"
}

test_exports_known_domains_and_skips_others() {
  setup_fake_defaults
  local out outdir
  outdir="$SANDBOX/out1"
  out="$(PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$outdir")"
  assert_contains "$out" "exported com.apple.dock" && \
  assert_contains "$out" "skipped NSGlobalDomain" && \
  [ -f "$outdir/dock.plist" ] && \
  [ -f "$outdir/finder.plist" ]
}

test_reports_counts() {
  setup_fake_defaults
  local out
  out="$(PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$SANDBOX/out2")"
  assert_contains "$out" "Exported: 2 domains" && assert_contains "$out" "Skipped:  7 domains"
}

test_creates_output_dir_if_missing() {
  setup_fake_defaults
  local outdir="$SANDBOX/does/not/exist/yet"
  PATH="$SANDBOX/bin:$PATH" bash "$SCRIPT" "$outdir" >/dev/null
  [ -d "$outdir" ]
}

echo "Running macos-defaults-export.sh tests..."
run_test "exports known domains, skips unknown"  test_exports_known_domains_and_skips_others
run_test "reports exported/skipped counts"        test_reports_counts
run_test "creates output dir if missing"          test_creates_output_dir_if_missing

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

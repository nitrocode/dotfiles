#!/bin/bash
# Tests for gha-latest-sha-check.sh
# Stubs `gh` via PATH and uses a sandbox HOME for the cache directory.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS_DIR/gha-latest-sha-check.sh"

PASS=0
FAIL=0
FAILED=()

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX"
  mkdir -p "$SANDBOX/.claude/hooks/cache"
  mkdir -p "$SANDBOX/bin"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown_sandbox() {
  rm -rf "$SANDBOX"
}

# Stub gh: handles `gh api repos/<repo>/releases/latest` and `gh api repos/<repo>/commits/<tag>`.
write_gh_stub() {
  local tag="$1" sha="$2"
  cat > "$SANDBOX/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"releases/latest"*) echo "$tag" ;;
  *"commits/$tag"*)    echo "$sha" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh"
}

run_test() {
  local name="$1"; shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
    printf "  FAIL  %s\n" "$name"
  fi
}

# Helper: invoke hook with a synthetic PostToolUse payload.
invoke_hook() {
  local file="$1"
  printf '{"tool_name":"Edit","tool_response":{"filePath":"%s"}}' "$file" | bash "$HOOK" 2>&1
}

# --------------------------------------------------------------------------

test_skips_non_workflow_files() {
  setup_sandbox
  write_gh_stub v6.0.2 ffffffffffffffffffffffffffffffffffffffff
  local f="$SANDBOX/random.yaml"
  echo "uses: actions/checkout@deadbeef00000000000000000000000000000000 # v4" > "$f"
  local out exit_code
  out=$(invoke_hook "$f"); exit_code=$?
  teardown_sandbox
  [[ $exit_code -eq 0 ]] && [[ "$out" != *"Auto-bumped"* ]]
}

test_skips_when_sha_already_latest() {
  setup_sandbox
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  write_gh_stub v6.0.2 "$sha"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  echo "      - uses: actions/checkout@$sha # v6.0.2" > "$f"
  local out exit_code orig
  orig=$(cat "$f")
  out=$(invoke_hook "$f"); exit_code=$?
  local result=0
  [[ $exit_code -eq 0 ]] || result=1
  [[ "$(cat "$f")" == "$orig" ]] || result=1
  [[ "$out" != *"Auto-bumped"* ]] || result=1
  teardown_sandbox
  return $result
}

test_bumps_outdated_sha() {
  setup_sandbox
  local latest_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  write_gh_stub v6.0.2 "$latest_sha"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
jobs:
  test:
    steps:
      - uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4
YML
  local out
  out=$(invoke_hook "$f")
  local result=0
  grep -q "actions/checkout@$latest_sha # v6.0.2" "$f" || result=1
  [[ "$out" == *"Auto-bumped"* ]] || result=1
  [[ "$out" == *"v6.0.2"* ]] || result=1
  teardown_sandbox
  return $result
}

test_handles_multiple_outdated() {
  setup_sandbox
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"actions/checkout/releases/latest"*)            echo v6.0.2 ;;
  *"actions/setup-python/releases/latest"*)        echo v6.2.0 ;;
  *"actions/checkout/commits/v6.0.2"*)             echo cccccccccccccccccccccccccccccccccccccccc ;;
  *"actions/setup-python/commits/v6.2.0"*)         echo dddddddddddddddddddddddddddddddddddddddd ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
      - uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4
      - uses: actions/setup-python@1111111111111111111111111111111111111111 # v5
YML
  local out
  out=$(invoke_hook "$f")
  local result=0
  grep -q 'actions/checkout@cccccccccccccccccccccccccccccccccccccccc # v6.0.2' "$f" || result=1
  grep -q 'actions/setup-python@dddddddddddddddddddddddddddddddddddddddd # v6.2.0' "$f" || result=1
  teardown_sandbox
  return $result
}

test_uses_cache_on_second_run() {
  setup_sandbox
  local sha="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  write_gh_stub v6.0.2 "$sha"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  echo "- uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4" > "$f"

  invoke_hook "$f" >/dev/null
  # Replace stub with one that exits non-zero; should still succeed via cache.
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$SANDBOX/bin/gh"
  echo "- uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4" > "$f"
  invoke_hook "$f" >/dev/null
  local result=0
  grep -q "actions/checkout@$sha # v6.0.2" "$f" || result=1
  teardown_sandbox
  return $result
}

test_skips_pin_locked_entry() {
  setup_sandbox
  local latest_sha="ffffeeeeddddccccbbbbaaaa9999888877776666"
  write_gh_stub v6.0.2 "$latest_sha"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
      - uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4 pin-lock
YML
  local out orig
  orig=$(cat "$f")
  out=$(invoke_hook "$f")
  local result=0
  [[ "$(cat "$f")" == "$orig" ]] || result=1
  [[ "$out" != *"Auto-bumped"* ]] || result=1
  teardown_sandbox
  return $result
}

test_bumps_non_locked_alongside_locked() {
  setup_sandbox
  cat > "$SANDBOX/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"actions/setup-python/releases/latest"*) echo v6.2.0 ;;
  *"actions/setup-python/commits/v6.2.0"*)  echo 2222222222222222222222222222222222222222 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$SANDBOX/bin/gh"
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'YML'
      - uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4 pin-lock
      - uses: actions/setup-python@1111111111111111111111111111111111111111 # v5
YML
  local out
  out=$(invoke_hook "$f")
  local result=0
  grep -q 'actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4 pin-lock' "$f" || result=1
  grep -q 'actions/setup-python@2222222222222222222222222222222222222222 # v6.2.0' "$f" || result=1
  teardown_sandbox
  return $result
}

test_silent_when_gh_missing() {
  setup_sandbox
  # No gh stub - PATH override removes it from common locations? Just write a
  # non-existent one and clear PATH for the test.
  local f="$SANDBOX/.github/workflows/ci.yml"
  mkdir -p "$(dirname "$f")"
  echo "- uses: actions/checkout@f43a0e5ff2bd294095638e18286ca9a3d1956744 # v4" > "$f"
  local orig
  orig=$(cat "$f")
  PATH="$SANDBOX/empty" invoke_hook "$f" >/dev/null
  local result=0
  [[ "$(cat "$f")" == "$orig" ]] || result=1
  teardown_sandbox
  return $result
}

# --------------------------------------------------------------------------

run_test "skips non-workflow files"        test_skips_non_workflow_files
run_test "no-op when sha already latest"   test_skips_when_sha_already_latest
run_test "bumps outdated sha"              test_bumps_outdated_sha
run_test "handles multiple outdated"       test_handles_multiple_outdated
run_test "uses cache on second run"        test_uses_cache_on_second_run
run_test "silent when gh missing"          test_silent_when_gh_missing
run_test "skips pin-locked entry"          test_skips_pin_locked_entry
run_test "bumps non-locked alongside locked" test_bumps_non_locked_alongside_locked

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi

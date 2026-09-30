#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/op-recover.sh.
# Mocks `op`, `pgrep`, and `open` via PATH shims so no real 1Password
# calls happen during tests. Focused on the new "spawn app if not running"
# behavior plus the happy paths.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/op-recover.sh"
echo "test-op-recover.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  STATE="$SANDBOX/state"
  mkdir -p "$SANDBOX/bin" "$STATE"
  OPEN_CALLS="$STATE/open-calls.txt"
  OP_CALLS="$STATE/op-calls.txt"
  : >"$OPEN_CALLS"
  : >"$OP_CALLS"

  # Mock `op`. Behavior controlled by env:
  #   OP_MOCK_WHOAMI_SUCCESS_AT (1-based count) = nth call where whoami starts succeeding
  #   OP_MOCK_SIGNIN_OUTPUT = string to emit on `signin` subcommand
  cat >"$SANDBOX/bin/op" <<'OP'
#!/bin/bash
set -u
STATE="${OP_MOCK_STATE:?need OP_MOCK_STATE}"
SUCCESS_AT="${OP_MOCK_WHOAMI_SUCCESS_AT:-1}"
SIGNIN_OUT="${OP_MOCK_SIGNIN_OUTPUT:-}"
sub="$1"; shift || true
case "$sub" in
  whoami)
    n=$(($(cat "$STATE/whoami-count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$STATE/whoami-count"
    if [ "$n" -ge "$SUCCESS_AT" ]; then
      echo "URL: https://example.1password.com/"
      exit 0
    fi
    echo "[ERROR] account not signed in" >&2
    exit 1
    ;;
  signin)
    if [ -n "$SIGNIN_OUT" ]; then
      printf '%s\n' "$SIGNIN_OUT"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
OP
  chmod +x "$SANDBOX/bin/op"

  # Mock `pgrep`. PGREP_MOCK_RUNNING=1 means the named process is "running".
  cat >"$SANDBOX/bin/pgrep" <<'PG'
#!/bin/bash
RUNNING="${PGREP_MOCK_RUNNING:-0}"
if [ "$RUNNING" = "1" ]; then
  echo 12345
  exit 0
fi
exit 1
PG
  chmod +x "$SANDBOX/bin/pgrep"

  # Mock `open`. Records every invocation to OPEN_CALLS. Also flips
  # PGREP_MOCK_RUNNING semantics by writing a marker so a subsequent pgrep
  # (re-invoked under the same shell) can detect that open was called.
  cat >"$SANDBOX/bin/open" <<OPEN
#!/bin/bash
echo "open \$*" >>"$OPEN_CALLS"
# After open is called, simulate the app coming up by enabling pgrep success
# on subsequent invocations within this script run.
echo 1 > "$STATE/app-launched"
OPEN
  chmod +x "$SANDBOX/bin/open"

  # Replace pgrep mock with one that consults the app-launched marker so we
  # accurately simulate "not running until open is called".
  cat >"$SANDBOX/bin/pgrep" <<'PG'
#!/bin/bash
STATE="${OP_MOCK_STATE:?need OP_MOCK_STATE}"
RUNNING="${PGREP_MOCK_RUNNING:-0}"
if [ "$RUNNING" = "1" ] || [ -f "$STATE/app-launched" ]; then
  echo 12345
  exit 0
fi
exit 1
PG
  chmod +x "$SANDBOX/bin/pgrep"

  export OP_MOCK_STATE="$STATE"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown_sandbox() {
  rm -rf "$SANDBOX"
  unset OP_MOCK_STATE PGREP_MOCK_RUNNING OP_MOCK_WHOAMI_SUCCESS_AT OP_MOCK_SIGNIN_OUTPUT
}

test_help_exits_zero() {
  setup_sandbox
  out=$(bash "$SCRIPT" --help 2>&1)
  rc=$?
  assert_eq 0 "$rc" "--help exit code"
  assert_contains "$out" "Recover 1Password CLI" "--help output"
  teardown_sandbox
}
run_test test_help_exits_zero

test_already_signed_in_skips_spawn() {
  setup_sandbox
  export OP_MOCK_WHOAMI_SUCCESS_AT=1
  export PGREP_MOCK_RUNNING=1
  out=$(bash "$SCRIPT" 2>&1)
  rc=$?
  assert_eq 0 "$rc" "already-signed-in exit code"
  assert_contains "$out" "already signed in" "already-signed-in message"
  open_count=$(wc -l <"$OPEN_CALLS" | tr -d ' ')
  assert_eq 0 "$open_count" "open should NOT be called when already signed in"
  teardown_sandbox
}
run_test test_already_signed_in_skips_spawn

test_app_not_running_spawns_then_succeeds() {
  setup_sandbox
  # whoami fails first time, succeeds on second (after spawn)
  export OP_MOCK_WHOAMI_SUCCESS_AT=2
  export PGREP_MOCK_RUNNING=0
  out=$(bash "$SCRIPT" 2>&1)
  rc=$?
  assert_eq 0 "$rc" "spawn-then-succeed exit code"
  assert_contains "$out" "not running" "detects app not running"
  assert_contains "$out" "signed in after launching app" "post-spawn success message"
  open_count=$(wc -l <"$OPEN_CALLS" | tr -d ' ')
  assert_eq 1 "$open_count" "open should be called exactly once"
  assert_contains "$(cat "$OPEN_CALLS")" "-ga 1Password" "open should be called with -ga 1Password"
  teardown_sandbox
}
run_test test_app_not_running_spawns_then_succeeds

test_app_running_skips_spawn() {
  setup_sandbox
  # whoami fails first time, succeeds on second (so script falls through past
  # the fast path), but pgrep says app IS running, so open should not be called.
  # Recovery still proceeds via the existing signin path; we exit non-zero here
  # because the mocked signin returns no session by default.
  export OP_MOCK_WHOAMI_SUCCESS_AT=99
  export PGREP_MOCK_RUNNING=1
  out=$(bash "$SCRIPT" 2>&1 || true)
  open_count=$(wc -l <"$OPEN_CALLS" | tr -d ' ')
  assert_eq 0 "$open_count" "open should NOT be called when app already running"
  teardown_sandbox
}
run_test test_app_running_skips_spawn

print_summary

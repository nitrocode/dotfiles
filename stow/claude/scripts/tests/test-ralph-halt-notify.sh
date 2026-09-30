#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/ralph-halt-notify.sh.
# Mocks `osascript`, `say`, and `jq` via PATH shims; runs the watcher as a
# background process against a sandboxed status.json and asserts on notify
# call counts recorded by the mocks.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/ralph-halt-notify.sh"
echo "test-ralph-halt-notify.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/project/.ralph"
  STATUS_FILE="$SANDBOX/project/.ralph/status.json"
  NOTIFY_CALLS="$SANDBOX/notify-calls.txt"
  SAY_CALLS="$SANDBOX/say-calls.txt"
  : >"$NOTIFY_CALLS"
  : >"$SAY_CALLS"

  cat >"$SANDBOX/bin/osascript" <<'OSA'
#!/bin/bash
echo "$*" >>"$NOTIFY_CALLS_FILE"
OSA
  cat >"$SANDBOX/bin/say" <<'SAY'
#!/bin/bash
echo "$*" >>"$SAY_CALLS_FILE"
SAY
  chmod +x "$SANDBOX/bin/osascript" "$SANDBOX/bin/say" 2>/dev/null || true

  write_status() {
    printf '{"status": "%s", "exit_reason": "%s"}\n' "$1" "$2" >"$STATUS_FILE"
  }

  # jq is a real, already-installed tool; no mock needed as long as it's on PATH.
  export PATH="$SANDBOX/bin:$PATH"
  export NOTIFY_CALLS_FILE="$NOTIFY_CALLS"
  export SAY_CALLS_FILE="$SAY_CALLS"
}

teardown_sandbox() {
  [ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null
  wait "${WATCHER_PID:-}" 2>/dev/null
  rm -rf "$SANDBOX"
}

start_watcher() {
  bash "$SCRIPT" "$SANDBOX/project" 1 >/dev/null 2>&1 &
  WATCHER_PID=$!
}

notify_count() { wc -l <"$NOTIFY_CALLS" | tr -d ' '; }
say_count() { wc -l <"$SAY_CALLS" | tr -d ' '; }

test_notifies_on_halt() {
  setup_sandbox
  write_status "running" ""
  start_watcher
  sleep 0.5
  write_status "halted" "permission_denied"
  sleep 2
  local n=$(notify_count) s=$(say_count)
  teardown_sandbox
  [ "$n" -ge 1 ] && [ "$s" -ge 1 ]
}

test_does_not_renotify_while_still_halted() {
  setup_sandbox
  write_status "halted" "permission_denied"
  start_watcher
  sleep 2.5
  local first=$(notify_count)
  sleep 2
  local second=$(notify_count)
  teardown_sandbox
  [ "$first" -ge 1 ] && [ "$first" -eq "$second" ]
}

test_renotifies_after_resume_then_halt_again() {
  setup_sandbox
  write_status "running" ""
  start_watcher
  sleep 0.5
  write_status "halted" "permission_denied"
  sleep 2
  local first=$(notify_count)
  write_status "running" ""
  sleep 1.5
  write_status "halted" "circuit_breaker_trip"
  sleep 2
  local second=$(notify_count)
  teardown_sandbox
  [ "$first" -eq 1 ] && [ "$second" -eq 2 ]
}

test_no_status_file_does_not_crash() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin"
  bash "$SCRIPT" "$SANDBOX/project-does-not-exist" 1 >/dev/null 2>&1 &
  WATCHER_PID=$!
  sleep 1
  local alive=1
  kill -0 "$WATCHER_PID" 2>/dev/null && alive=0
  teardown_sandbox
  [ "$alive" -eq 0 ]
}

run_test "notifies (with sound) when status flips to halted" test_notifies_on_halt
run_test "does not re-notify on repeated polls while still halted" test_does_not_renotify_while_still_halted
run_test "notifies again after a resume-then-halt cycle" test_renotifies_after_resume_then_halt_again
run_test "missing status.json does not crash the watcher" test_no_status_file_does_not_crash

print_summary
[ "$FAIL" -eq 0 ]

#!/bin/bash
# Tests for $CLAUDE_CONFIG_DIR/scripts/off-hours-nag.sh: fires on before/after
# hours and weekend/holiday, stays silent during business hours, respects
# the launchctl-env override, rate-limits re-nags, re-nags immediately on
# a reason change, and forces volume up + unmuted (then restores it)
# around the sound. Mocks `launchctl`, `osascript`, and `afplay` via a
# PATH shim; never touches the real per-session env, volume, or fires a
# real notification/sound.
# Run: bash $CLAUDE_CONFIG_DIR/scripts/tests/test-off-hours-nag.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../hooks/tests/_lib.sh
source $CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/off-hours-nag.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/launchctl" <<'EOF'
#!/bin/bash
if [ "$1" = "getenv" ] && [ "$2" = "CCUSAGE_ALLOW_OFF_HOURS" ]; then
  echo -n "${FAKE_OVERRIDE:-}"
  exit 0
fi
exit 0
EOF
# Logs every invocation (not just the notification call) so tests can
# also assert on the volume-set/restore calls. Answers "get volume
# settings" with a fixed fake prior state (37, unmuted) so the script's
# restore-afterward branch has something concrete to parse and restore.
cat > "$SANDBOX/bin/osascript" <<'EOF'
#!/bin/bash
echo "OSASCRIPT: $*" >> "$OSASCRIPT_LOG"
if [ "$1" = "-e" ] && [ "$2" = "get volume settings" ]; then
  echo "output volume:37, input volume:75, alert volume:100, output muted:false"
fi
EOF
cat > "$SANDBOX/bin/afplay" <<'EOF'
#!/bin/bash
echo "AFPLAY: $*" >> "$OSASCRIPT_LOG"
EOF
chmod +x "$SANDBOX/bin/launchctl" "$SANDBOX/bin/osascript" "$SANDBOX/bin/afplay" 2>/dev/null || true
FAKE_SOUND_FILE="$SANDBOX/fake-sound.aiff"
: > "$FAKE_SOUND_FILE"

# Runs the nag script with a fresh state file + mocked launchctl/osascript/
# afplay. Args: today  now_hhmm  extra_env_assignments...
run_nag() {
  local today="$1" now_hhmm="$2"
  shift 2
  local state_file="$SANDBOX/state-$$-$RANDOM"
  local log_file="$SANDBOX/log-$$-$RANDOM.txt"
  env "$@" PATH="$SANDBOX/bin:$PATH" CCUSAGE_NAG_STATE_FILE="$state_file" \
    OSASCRIPT_LOG="$log_file" CCUSAGE_STATUSLINE_TODAY="$today" \
    CCUSAGE_STATUSLINE_NOW_HHMM="$now_hhmm" CCUSAGE_NAG_SOUND_FILE="$FAKE_SOUND_FILE" \
    bash "$SCRIPT" >/dev/null 2>&1
  cat "$log_file" 2>/dev/null || true
}

# Same as run_nag but reuses an existing state file, for rate-limit checks.
run_nag_with_state() {
  local today="$1" now_hhmm="$2" state_file="$3" log_file="$4"
  shift 4
  env "$@" PATH="$SANDBOX/bin:$PATH" CCUSAGE_NAG_STATE_FILE="$state_file" \
    OSASCRIPT_LOG="$log_file" CCUSAGE_STATUSLINE_TODAY="$today" \
    CCUSAGE_STATUSLINE_NOW_HHMM="$now_hhmm" CCUSAGE_NAG_SOUND_FILE="$FAKE_SOUND_FILE" \
    bash "$SCRIPT" >/dev/null 2>&1
}

test_fires_after_hours() {
  local out
  out=$(run_nag 2026-09-03 19:30)
  case "$out" in *"display notification"*"Consider logging off"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_fires_before_hours() {
  local out
  out=$(run_nag 2026-09-03 07:15)
  case "$out" in *"display notification"*"No rush to start"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_silent_during_business_hours() {
  local out
  out=$(run_nag 2026-09-03 14:00)
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

test_fires_on_weekend() {
  local out
  out=$(run_nag 2026-09-05 14:00)  # Saturday
  case "$out" in *"display notification"*"weekend"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_fires_on_holiday() {
  local out
  out=$(run_nag 2026-09-07 14:00)  # Labor Day 2026, a Monday
  case "$out" in *"display notification"*"holiday"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_forces_volume_up_and_unmuted() {
  local out
  out=$(run_nag 2026-09-03 19:30)
  case "$out" in *"set volume output volume 100 output muted false"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_plays_sound_file_via_afplay() {
  local out
  out=$(run_nag 2026-09-03 19:30)
  case "$out" in *"AFPLAY: $FAKE_SOUND_FILE"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_plays_sound_repeat_count_times() {
  local state_file="$SANDBOX/repeat-state" log_file="$SANDBOX/repeat-log.txt"
  run_nag_with_state 2026-09-03 19:30 "$state_file" "$log_file" CCUSAGE_NAG_REPEAT_COUNT=3
  local count
  count=$(grep -c "^AFPLAY:" "$log_file" 2>/dev/null || true)
  [ "$count" = "3" ] || { echo "    expected 3 AFPLAY calls, got $count" >&2; return 1; }
}

test_restores_prior_volume_after() {
  local out
  out=$(run_nag 2026-09-03 19:30)
  # Mock "get volume settings" reports 37/unmuted as the prior state.
  case "$out" in *"set volume output volume 37 output muted false"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_no_volume_calls_when_suppressed_by_override() {
  local out
  out=$(run_nag 2026-09-03 19:30 FAKE_OVERRIDE=1)
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

test_override_suppresses_after_hours() {
  local out
  out=$(run_nag 2026-09-03 19:30 FAKE_OVERRIDE=1)
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

test_override_suppresses_weekend() {
  local out
  out=$(run_nag 2026-09-05 14:00 FAKE_OVERRIDE=1)
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

# Counts actual nag firings (the "display notification" line), not raw
# log lines, since each firing now logs several volume-control calls too.
count_nags() {
  grep -c "display notification" "$1" 2>/dev/null || true
}

test_rate_limit_suppresses_repeat_within_interval() {
  local state_file="$SANDBOX/rl-state" log_file="$SANDBOX/rl-log.txt"
  run_nag_with_state 2026-09-03 19:30 "$state_file" "$log_file"
  local first_count
  first_count=$(count_nags "$log_file")
  run_nag_with_state 2026-09-03 19:35 "$state_file" "$log_file"
  local second_count
  second_count=$(count_nags "$log_file")
  [ "$first_count" = "1" ] || { echo "    expected first call to fire once, got $first_count" >&2; return 1; }
  [ "$second_count" = "1" ] || { echo "    expected second call within interval to be suppressed, got $second_count" >&2; return 1; }
}

test_reason_change_forces_immediate_renag() {
  local state_file="$SANDBOX/rc-state" log_file="$SANDBOX/rc-log.txt"
  run_nag_with_state 2026-09-03 07:15 "$state_file" "$log_file"  # before_hours
  run_nag_with_state 2026-09-05 07:20 "$state_file" "$log_file"  # weekend (different reason)
  local count
  count=$(count_nags "$log_file")
  [ "$count" = "2" ] || { echo "    expected a reason change to re-fire immediately, got $count" >&2; return 1; }
}

test_interval_expiry_allows_renag() {
  local state_file="$SANDBOX/exp-state" log_file="$SANDBOX/exp-log.txt"
  printf '0 after_hours' > "$state_file"  # fake "long ago" last nag
  run_nag_with_state 2026-09-03 19:30 "$state_file" "$log_file"
  local count
  count=$(count_nags "$log_file")
  [ "$count" = "1" ] || { echo "    expected an expired interval to allow a re-nag, got $count" >&2; return 1; }
}

run_test "fires when past business hours" test_fires_after_hours
run_test "fires before business hours" test_fires_before_hours
run_test "silent during business hours" test_silent_during_business_hours
run_test "fires on a weekend" test_fires_on_weekend
run_test "fires on a holiday" test_fires_on_holiday
run_test "forces volume up and unmuted before the sound" test_forces_volume_up_and_unmuted
run_test "plays the sound file via afplay" test_plays_sound_file_via_afplay
run_test "plays the sound CCUSAGE_NAG_REPEAT_COUNT times" test_plays_sound_repeat_count_times
run_test "restores prior volume/mute state after" test_restores_prior_volume_after
run_test "no volume calls when suppressed by override" test_no_volume_calls_when_suppressed_by_override
run_test "launchctl override suppresses after-hours nag" test_override_suppresses_after_hours
run_test "launchctl override suppresses weekend nag" test_override_suppresses_weekend
run_test "rate limit suppresses a repeat within the interval" test_rate_limit_suppresses_repeat_within_interval
run_test "a reason change forces an immediate re-nag" test_reason_change_forces_immediate_renag
run_test "an expired interval allows a re-nag" test_interval_expiry_allows_renag

print_summary

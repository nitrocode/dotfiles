#!/bin/bash
# Tests for ~/.claude/statusline-command.sh: render_cost_segment color
# thresholds, fetch_month_data caching, the pace/spent-today/headroom/
# days-left/last-month/weekend-holiday/business-hours segments, portable
# date helpers (both the GNU and real BSD `date` codepaths), and the
# holiday-list staleness self-check. Mocks `ccusage` via a PATH shim;
# never calls the real binary or reads real session logs.
# Run: bash ~/.claude/hooks/tests/test-statusline-command.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TEST_DIR/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/statusline-command.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Source the whole "pure-testable region" (config vars, HOLIDAYS_2026,
# portable date helpers, every render_*/is_*/count_*/compute_* function)
# between its sentinel comments, without running the rest of the script
# (which reads stdin and hits the cache/ccusage path).
PURE_FUNCS="$SANDBOX/pure-funcs.sh"
sed -n '/^# --- BEGIN PURE-TESTABLE REGION/,/^# --- END PURE-TESTABLE REGION/p' "$SCRIPT" > "$PURE_FUNCS"
source "$PURE_FUNCS"

BASE_INPUT='{"model":{"display_name":"Sonnet 5"},"workspace":{"current_dir":"/tmp"},"cwd":"/tmp","output_style":{"name":"default"}}'

# Runs the statusline script with a fresh cache file and PATH, returning stdout.
# Args: cache_file_contents_or_empty  extra_env_assignments...
run_statusline() {
  local cache_contents="$1"
  shift
  local cache_file="$SANDBOX/cache-$$-$RANDOM.json"
  if [ -n "$cache_contents" ]; then
    printf '%s' "$cache_contents" > "$cache_file"
  fi
  env "$@" CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" PATH="$SANDBOX/bin:$PATH" \
    bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'"
}

make_fake_ccusage() {
  # Single row dated today: sums to $total_cost for the month and matches
  # "today". No previous-month rows, so last-month/trend segments stay
  # absent for tests using this (covered separately below).
  local total_cost="$1"
  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/ccusage" <<EOF
#!/bin/bash
today=\$(date +%Y-%m-%d)
echo '{"daily":[{"period":"'"\$today"'","totalCost":$total_cost}]}'
EOF
  chmod +x "$SANDBOX/bin/ccusage" 2>/dev/null || true
}

# Cache file for "current month, fresh" so cache-hit tests don't depend on
# a mocked `date`.
fresh_cache() {
  local cost="$1"
  local month now
  month=$(date +%Y-%m)
  now=$(date +%s)
  printf '{"month":"%s","totalCost":%s,"fetchedAt":%s}' "$month" "$cost" "$now"
}

test_green_under_60_pct() {
  make_fake_ccusage 999999  # would be wrong if called; cache should win
  local out
  out=$(run_statusline "$(fresh_cache 200)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" $'\033[32m$200/$2000 (10%)'
}

test_yellow_60_to_84_pct() {
  local out
  out=$(run_statusline "$(fresh_cache 1400)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" $'\033[33m$1400/$2000 (70%)'
}

test_orange_85_to_99_pct() {
  local out
  out=$(run_statusline "$(fresh_cache 1900)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" $'\033[38;5;208m$1900/$2000 (95%)'
}

test_red_at_or_over_100_pct() {
  local out
  out=$(run_statusline "$(fresh_cache 2500)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" $'\033[31m$2500/$2000 (125%)'
}

test_cache_hit_never_calls_ccusage() {
  # No fake ccusage on PATH at all: if the script tried to call it, the
  # `command -v ccusage` check would fail and cost would fall back to 0.
  # A fresh cache must be used instead, proving the cache path short-circuits.
  local out
  out=$(run_statusline "$(fresh_cache 300)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" '$300/$2000'
}

test_cache_miss_calls_ccusage_and_writes_cache() {
  make_fake_ccusage 42
  local cache_file="$SANDBOX/miss-cache.json"
  rm -f "$cache_file"
  local out
  out=$(env CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" CCUSAGE_BUDGET_MONTHLY=2000 \
    PATH="$SANDBOX/bin:$PATH" bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'")
  if ! printf '%s' "$out" | grep -q '\$42/\$2000'; then
    printf '    expected $42/$2000 in output, got: %s\n' "$out" >&2
    return 1
  fi
  [ -f "$cache_file" ] || { echo "    expected cache file to be written" >&2; return 1; }
  jq -e '.totalCost == 42' "$cache_file" >/dev/null 2>&1
}

test_stale_cache_triggers_refetch() {
  make_fake_ccusage 77
  local cache_file="$SANDBOX/stale-cache.json"
  local month
  month=$(date +%Y-%m)
  # fetchedAt far in the past -> stale under any reasonable TTL
  printf '{"month":"%s","totalCost":9999,"fetchedAt":0}' "$month" > "$cache_file"
  local out
  out=$(env CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" CCUSAGE_STATUSLINE_CACHE_TTL=300 \
    CCUSAGE_BUDGET_MONTHLY=2000 PATH="$SANDBOX/bin:$PATH" \
    bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'")
  assert_contains "$out" '$77/$2000'
}

test_ccusage_missing_falls_back_to_zero() {
  # PATH with everything the script needs EXCEPT ccusage (symlink real
  # binaries into an isolated dir rather than trusting real PATH dirs,
  # since ccusage lives alongside jq/date on this machine).
  local cache_file="$SANDBOX/no-ccusage-cache.json"
  rm -f "$cache_file"
  local no_ccusage_bin="$SANDBOX/no-ccusage-bin"
  mkdir -p "$no_ccusage_bin"
  for tool in jq bash awk date grep basename dirname tr git env cat mktemp printf command sed; do
    local real
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$no_ccusage_bin/$tool" 2>/dev/null || true
  done
  local out
  out=$(env CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" CCUSAGE_BUDGET_MONTHLY=2000 \
    PATH="$no_ccusage_bin" bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'")
  assert_contains "$out" '$0/$2000 (0%)'
}

test_default_budget_is_2000() {
  local out
  out=$(run_statusline "$(fresh_cache 500)")
  assert_contains "$out" '/$2000 ('
}

# Cache file including weekday counts, for exercising the "pace" segment.
fresh_cache_full() {
  local cost="$1" elapsed="$2" remaining="$3"
  local month now
  month=$(date +%Y-%m)
  now=$(date +%s)
  printf '{"month":"%s","totalCost":%s,"weekdayElapsed":%s,"weekdayRemaining":%s,"fetchedAt":%s}' \
    "$month" "$cost" "$elapsed" "$remaining" "$now"
}

# --- count_weekdays (pure, date-injected) ---

test_count_weekdays_early_month() {
  # Sep 2026: Tue Sep 1 is the first weekday. Sep 3 (Thu) is the 3rd weekday.
  # 22 Mon-Fri days minus Labor Day (Sep 7, a holiday) = 21 business days.
  local out
  out=$(CCUSAGE_STATUSLINE_TODAY=2026-09-03 count_weekdays)
  [ "$out" = "3 19 21" ] || { echo "    got: $out" >&2; return 1; }
}

test_count_weekdays_last_day_of_month() {
  # Sep 30, 2026 is a Wednesday, the month's last business day (21st, after
  # excluding the Sep 7 Labor Day holiday from the 22 Mon-Fri days).
  local out
  out=$(CCUSAGE_STATUSLINE_TODAY=2026-09-30 count_weekdays)
  [ "$out" = "21 1 21" ] || { echo "    got: $out" >&2; return 1; }
}

test_count_weekdays_on_a_weekend_still_counts_nearest() {
  # Sep 5, 2026 is a Saturday. The function doesn't special-case weekends
  # for "today" itself, it just compares day-of-month; document that here
  # rather than let it silently drift. Remaining excludes the Sep 7 Labor
  # Day holiday, which is >= today_day.
  local out
  out=$(CCUSAGE_STATUSLINE_TODAY=2026-09-05 count_weekdays)
  [ "$out" = "4 17 21" ] || { echo "    got: $out" >&2; return 1; }
}

# --- advance_weekdays (pure) ---

test_advance_weekdays_skips_weekend() {
  # From Fri Sep 4, 2026 forward 1 business day must skip the weekend AND
  # the Sep 7 Labor Day holiday, landing on Tue Sep 8.
  local out
  out=$(advance_weekdays "2026-09-04" 1)
  [ "$out" = "Sep 8" ] || { echo "    got: $out" >&2; return 1; }
}

test_advance_weekdays_zero_returns_from_date() {
  local out
  out=$(advance_weekdays "2026-09-15" 0)
  [ "$out" = "Sep 15" ] || { echo "    got: $out" >&2; return 1; }
}

# --- project_exhaustion_date (pure) ---

test_project_exhaustion_date_normal_case() {
  # 19 business days out from Sep 2 lands on Sep 30, one day later than
  # before the holiday fix since day 19 now has to skip the Sep 7 holiday.
  local out
  out=$(project_exhaustion_date 2000 199.20 99.60 "2026-09-02")
  [ "$out" = "Sep 30" ] || { echo "    got: $out" >&2; return 1; }
}

test_project_exhaustion_date_already_over_budget() {
  local out
  out=$(project_exhaustion_date 2000 2100 50 "2026-09-03")
  [ "$out" = "Sep 3" ] || { echo "    got: $out" >&2; return 1; }
}

test_project_exhaustion_date_zero_avg_fails() {
  project_exhaustion_date 2000 199 0 "2026-09-03" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -ne 0 ]
}

# --- portable date helpers: GNU codepath (whatever `date` is on real PATH) ---

test_date_dow_gnu() {
  local out
  out=$(date_dow "2026-09-07")  # Labor Day, a Monday
  [ "$out" = "1" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_add_days_gnu() {
  local out
  out=$(date_add_days "2026-09-04" 1)
  [ "$out" = "2026-09-05" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_month_last_day_gnu() {
  local out
  out=$(date_month_last_day "2026" "09")
  [ "$out" = "30" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_fmt_short_gnu() {
  local out
  out=$(date_fmt_short "2026-09-07")
  [ "$out" = "Sep 7" ] || { echo "    got: $out" >&2; return 1; }
}

# --- portable date helpers: real BSD `date` codepath ---
# PATH restricted to /usr/bin:/bin so `date` resolves to the actual macOS
# BSD date (no --version support), not Homebrew coreutils, re-sourcing
# PURE_FUNCS fresh in that PATH so DATE_BIN_IS_GNU auto-detects to 0.

test_date_dow_bsd_fallback() {
  local out
  out=$(PATH="/usr/bin:/bin" bash -c "source '$PURE_FUNCS'; date_dow 2026-09-07")
  [ "$out" = "1" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_add_days_bsd_fallback() {
  local out
  out=$(PATH="/usr/bin:/bin" bash -c "source '$PURE_FUNCS'; date_add_days 2026-09-04 1")
  [ "$out" = "2026-09-05" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_month_last_day_bsd_fallback() {
  local out
  out=$(PATH="/usr/bin:/bin" bash -c "source '$PURE_FUNCS'; date_month_last_day 2026 09")
  [ "$out" = "30" ] || { echo "    got: $out" >&2; return 1; }
}

test_date_fmt_short_bsd_fallback() {
  local out
  out=$(PATH="/usr/bin:/bin" bash -c "source '$PURE_FUNCS'; date_fmt_short 2026-09-07")
  [ "$out" = "Sep 7" ] || { echo "    got: $out" >&2; return 1; }
}

test_advance_weekdays_bsd_fallback() {
  # End-to-end through the BSD codepath: Fri Sep 4 2026 + 1 business day
  # skips both the weekend and the Sep 7 Labor Day holiday -> Tue Sep 8.
  local out
  out=$(PATH="/usr/bin:/bin" bash -c "source '$PURE_FUNCS'; advance_weekdays 2026-09-04 1")
  [ "$out" = "Sep 8" ] || { echo "    got: $out" >&2; return 1; }
}

# --- end-to-end "pace" segment ---

test_pace_segment_under_pace_green_no_runway() {
  local out
  out=$(run_statusline "$(fresh_cache_full 100 5 17)" CCUSAGE_BUDGET_MONTHLY=2000)
  # avg = 100/5 = 20, target = (2000-100)/17 ≈ 111.76 -> well under, green
  assert_contains "$out" 'pace '$'\033[32m'
  case "$out" in
    *"out ~"*) echo "    expected no runway warning when under pace, got: $out" >&2; return 1 ;;
  esac
}

test_pace_segment_over_pace_shows_red_and_runway() {
  local out
  out=$(run_statusline "$(fresh_cache_full 199.20 2 20)" CCUSAGE_BUDGET_MONTHLY=2000)
  # avg = 99.60, target = (2000-199.20)/20 = 90.04 -> avg > target, red + runway
  assert_contains "$out" 'pace '$'\033[31m' || return 1
  assert_contains "$out" 'out ~'
}

test_pace_segment_absent_when_no_weekday_data() {
  # Old cache shape (pre-weekday-fields) or weekdayElapsed=0: pace segment
  # and runway must both be omitted, not error.
  local out
  out=$(run_statusline "$(fresh_cache 500)" CCUSAGE_BUDGET_MONTHLY=2000)
  case "$out" in
    *"pace "*) echo "    expected no pace segment without weekday data, got: $out" >&2; return 1 ;;
  esac
}

# --- render_pace_segment (pure, trend arrows) ---

test_pace_segment_trend_up_arrow() {
  local out
  out=$(render_pace_segment 20 111.76 up)
  case "$out" in *"📈"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_pace_segment_trend_down_arrow() {
  local out
  out=$(render_pace_segment 20 111.76 down)
  case "$out" in *"📉"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_pace_segment_no_trend_no_arrow() {
  local out
  out=$(render_pace_segment 20 111.76 NA)
  case "$out" in *"📈"*|*"📉"*|*"➖"*) echo "    expected no trend arrow, got: $out" >&2; return 1 ;; esac
}

# --- render_spent_today_segment (pure) ---

test_spent_today_under_baseline_green() {
  local out
  out=$(render_spent_today_segment 8 20)
  [ "$out" = $'\033[32m💸 $8 today ▼$12 avg/day\033[0m' ] || { echo "    got: $out" >&2; return 1; }
}

test_spent_today_over_baseline_red() {
  local out
  out=$(render_spent_today_segment 22 8)
  [ "$out" = $'\033[31m💸 $22 today ▲$14 avg/day\033[0m' ] || { echo "    got: $out" >&2; return 1; }
}

test_spent_today_no_baseline_neutral() {
  local out
  out=$(render_spent_today_segment 22 "NA")
  [ "$out" = $'\033[2m💸 $22 today\033[0m' ] || { echo "    got: $out" >&2; return 1; }
}

# --- is_weekend_or_holiday (pure, date-injected) ---

test_is_weekend_saturday() {
  local out
  out=$(is_weekend_or_holiday "2026-09-05")  # Saturday
  [ "$out" = "weekend" ] || { echo "    got: $out" >&2; return 1; }
}

test_is_holiday_known_date() {
  local out
  out=$(is_weekend_or_holiday "2026-09-07")  # Labor Day, a Monday
  [ "$out" = "holiday" ] || { echo "    got: $out" >&2; return 1; }
}

test_is_weekend_or_holiday_absent_on_normal_weekday() {
  local out
  out=$(is_weekend_or_holiday "2026-09-03")  # a normal Thursday
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

# --- render_calendar_segment (pure) ---

test_calendar_segment_weekend_emoji() {
  local out
  out=$(render_calendar_segment "weekend")
  case "$out" in *"🏖️"*"weekend"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_calendar_segment_holiday_emoji() {
  local out
  out=$(render_calendar_segment "holiday")
  case "$out" in *"🎉"*"holiday"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_calendar_segment_empty_flag_is_absent() {
  local out
  out=$(render_calendar_segment "")
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

# --- render_business_hours_segment (pure) ---

test_business_hours_before_start() {
  local out
  out=$(render_business_hours_segment 08 30 9 17)
  case "$out" in *"🌙"*"before hours"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_business_hours_during_shows_countdown() {
  local out
  out=$(render_business_hours_segment 16 45 9 17)
  case "$out" in *"⏰"*"15m left"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_business_hours_during_hours_and_minutes() {
  local out
  out=$(render_business_hours_segment 09 05 9 17)
  case "$out" in *"⏰"*"7h 55m left"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_business_hours_at_end_boundary_is_after() {
  # 17:00 sharp: end_hour is exclusive, so this is already "after hours".
  local out
  out=$(render_business_hours_segment 17 00 9 17)
  case "$out" in *"🌙"*"after hours"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_business_hours_after_end() {
  local out
  out=$(render_business_hours_segment 19 30 9 17)
  case "$out" in *"🌙"*"after hours"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_business_hours_zero_padded_hour_not_octal() {
  # "09" must not be misread as an invalid octal literal in bash arithmetic.
  local out
  out=$(render_business_hours_segment 09 00 9 17)
  case "$out" in *"⏰"*"8h 0m left"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

# --- end-to-end business-hours wiring ---

test_business_hours_end_to_end_on_weekday() {
  local out
  out=$(run_statusline "$(fresh_cache_full 100 3 19)" CCUSAGE_BUDGET_MONTHLY=2000 \
    CCUSAGE_STATUSLINE_TODAY=2026-09-03 CCUSAGE_STATUSLINE_NOW_HHMM=14:22)
  assert_contains "$out" '⏰'
}

test_business_hours_end_to_end_suppressed_on_weekend() {
  # Sep 5, 2026 is a Saturday: the weekend flag should win and the
  # business-hours segment should not also appear.
  local out
  out=$(run_statusline "$(fresh_cache_full 100 3 19)" CCUSAGE_BUDGET_MONTHLY=2000 \
    CCUSAGE_STATUSLINE_TODAY=2026-09-05 CCUSAGE_STATUSLINE_NOW_HHMM=14:22)
  assert_contains "$out" '🏖️ weekend'
  case "$out" in *"⏰"*|*"🌙"*) echo "    expected no business-hours segment on a weekend, got: $out" >&2; return 1 ;; esac
}

# --- holiday_staleness_segment (pure) ---

test_holiday_staleness_fires_within_window() {
  local out
  out=$(holiday_staleness_segment "2026-12-05" "2027-01-01" 30)  # 27 days out
  case "$out" in *"update holiday list"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_holiday_staleness_fires_once_past_last_date() {
  local out
  out=$(holiday_staleness_segment "2027-01-15" "2027-01-01" 30)
  case "$out" in *"update holiday list"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_holiday_staleness_absent_outside_window() {
  local out
  out=$(holiday_staleness_segment "2026-09-03" "2027-01-01" 30)  # ~4 months out
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

# --- compute_trend (pure) ---

test_compute_trend_up() {
  local out
  out=$(compute_trend 20 10)  # +100% swing
  [ "$out" = "up" ] || { echo "    got: $out" >&2; return 1; }
}

test_compute_trend_down() {
  local out
  out=$(compute_trend 5 10)  # -50% swing
  [ "$out" = "down" ] || { echo "    got: $out" >&2; return 1; }
}

test_compute_trend_flat() {
  local out
  out=$(compute_trend 10.2 10)  # +2% swing, inside the 5% band
  [ "$out" = "flat" ] || { echo "    got: $out" >&2; return 1; }
}

test_compute_trend_no_prior_signal() {
  local out
  out=$(compute_trend 10 0)
  [ "$out" = "NA" ] || { echo "    got: $out" >&2; return 1; }
}

# --- render_days_left_segment (pure) ---

test_days_left_segment_plural() {
  local out
  out=$(render_days_left_segment 12)
  case "$out" in *"12 biz days left"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_days_left_segment_singular() {
  local out
  out=$(render_days_left_segment 1)
  case "$out" in *"1 biz day left"*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

# --- render_last_month_segment (pure) ---

test_last_month_segment_over() {
  local out
  out=$(render_last_month_segment 224 198)
  case "$out" in *'$198'*'(+$26)'*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
  case "$out" in *'$224'*) echo "    expected no repeat of this month's total, got: $out" >&2; return 1 ;; esac
}

test_last_month_segment_under() {
  local out
  out=$(render_last_month_segment 150 198)
  case "$out" in *'$198'*'(-$48)'*) : ;; *) echo "    got: $out" >&2; return 1 ;; esac
}

test_last_month_segment_absent_when_na() {
  local out
  out=$(render_last_month_segment 150 "NA")
  [ -z "$out" ] || { echo "    got: $out" >&2; return 1; }
}

# --- render_headroom_segment (pure) ---

test_headroom_segment_format() {
  local out
  out=$(render_headroom_segment 1820 2000)
  [ "$out" = $'\033[36m🚀 $180 left to spend\033[0m' ] || { echo "    got: $out" >&2; return 1; }
}

# --- end-to-end "spent today" segment ---

test_spent_today_end_to_end_over_baseline() {
  local cache_file="$SANDBOX/today-cache.json"
  local month
  month=$(date +%Y-%m)
  printf '{"month":"%s","totalCost":100,"weekdayElapsed":3,"weekdayRemaining":19,"weekdayTotal":22,"todayCost":30,"priorWeekdayAvg":10,"fetchedAt":%s}' \
    "$month" "$(date +%s)" > "$cache_file"
  local out
  out=$(env CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" CCUSAGE_BUDGET_MONTHLY=2000 \
    bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'")
  assert_contains "$out" $'\033[31m💸 $30 today ▲$20 avg/day\033[0m'
}

# --- end-to-end "days left" segment ---

test_days_left_end_to_end() {
  local out
  out=$(run_statusline "$(fresh_cache_full 100 5 17)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" '17 biz days left'
}

# --- end-to-end "headroom" segment (mutual exclusion with "out ~") ---

test_headroom_segment_fires_when_pace_is_low() {
  # month=100, elapsed=10, remaining=12, total=22: avg=10, target=(2000-100)/12≈158
  # -> nowhere near over pace. proj = 100 + 10*(22-10) = 220, well under 90% of 2000.
  local cache_file="$SANDBOX/underspend-cache.json"
  local month
  month=$(date +%Y-%m)
  printf '{"month":"%s","totalCost":100,"weekdayElapsed":10,"weekdayRemaining":12,"weekdayTotal":22,"todayCost":10,"priorWeekdayAvg":10,"fetchedAt":%s}' \
    "$month" "$(date +%s)" > "$cache_file"
  local out
  out=$(env CCUSAGE_STATUSLINE_CACHE_FILE="$cache_file" CCUSAGE_BUDGET_MONTHLY=2000 \
    bash -c "printf '%s' '$BASE_INPUT' | bash '$SCRIPT'")
  assert_contains "$out" '🚀' || return 1
  case "$out" in
    *"out ~"*) echo "    expected no runway warning alongside headroom, got: $out" >&2; return 1 ;;
  esac
}

test_headroom_segment_absent_when_over_pace() {
  # Reuses the existing over-pace fixture: avg=99.60 > target=90.04, so
  # "out ~" fires and headroom must not (mutual-exclusion guard).
  local out
  out=$(run_statusline "$(fresh_cache_full 199.20 2 20)" CCUSAGE_BUDGET_MONTHLY=2000)
  assert_contains "$out" 'out ~' || return 1
  case "$out" in
    *"🚀"*) echo "    expected no headroom segment when over pace, got: $out" >&2; return 1 ;;
  esac
}

run_test "date_dow (GNU codepath)" test_date_dow_gnu
run_test "date_add_days (GNU codepath)" test_date_add_days_gnu
run_test "date_month_last_day (GNU codepath)" test_date_month_last_day_gnu
run_test "date_fmt_short (GNU codepath)" test_date_fmt_short_gnu
run_test "date_dow (real BSD date fallback)" test_date_dow_bsd_fallback
run_test "date_add_days (real BSD date fallback)" test_date_add_days_bsd_fallback
run_test "date_month_last_day (real BSD date fallback)" test_date_month_last_day_bsd_fallback
run_test "date_fmt_short (real BSD date fallback)" test_date_fmt_short_bsd_fallback
run_test "advance_weekdays end-to-end (real BSD date fallback)" test_advance_weekdays_bsd_fallback
run_test "spent today: under baseline is green with ▼-delta" test_spent_today_under_baseline_green
run_test "spent today: over baseline is red with ▲-delta" test_spent_today_over_baseline_red
run_test "spent today: no baseline yet is neutral, no delta" test_spent_today_no_baseline_neutral
run_test "is_weekend_or_holiday: Saturday" test_is_weekend_saturday
run_test "is_weekend_or_holiday: known holiday (Labor Day)" test_is_holiday_known_date
run_test "is_weekend_or_holiday: absent on a normal weekday" test_is_weekend_or_holiday_absent_on_normal_weekday
run_test "calendar segment: weekend emoji" test_calendar_segment_weekend_emoji
run_test "calendar segment: holiday emoji" test_calendar_segment_holiday_emoji
run_test "calendar segment: empty flag is absent" test_calendar_segment_empty_flag_is_absent
run_test "business hours: before start" test_business_hours_before_start
run_test "business hours: during, shows minutes-only countdown" test_business_hours_during_shows_countdown
run_test "business hours: during, shows hours+minutes countdown" test_business_hours_during_hours_and_minutes
run_test "business hours: end boundary (17:00) is already after" test_business_hours_at_end_boundary_is_after
run_test "business hours: after end" test_business_hours_after_end
run_test "business hours: zero-padded hour isn't misread as octal" test_business_hours_zero_padded_hour_not_octal
run_test "business hours end-to-end: shown on a weekday" test_business_hours_end_to_end_on_weekday
run_test "business hours end-to-end: suppressed on a weekend" test_business_hours_end_to_end_suppressed_on_weekend
run_test "holiday staleness: fires within window" test_holiday_staleness_fires_within_window
run_test "holiday staleness: fires once past last date" test_holiday_staleness_fires_once_past_last_date
run_test "holiday staleness: absent outside window" test_holiday_staleness_absent_outside_window
run_test "compute_trend: up" test_compute_trend_up
run_test "compute_trend: down" test_compute_trend_down
run_test "compute_trend: flat" test_compute_trend_flat
run_test "compute_trend: no prior signal" test_compute_trend_no_prior_signal
run_test "days left segment: plural" test_days_left_segment_plural
run_test "days left segment: singular" test_days_left_segment_singular
run_test "last month segment: over" test_last_month_segment_over
run_test "last month segment: under" test_last_month_segment_under
run_test "last month segment: absent when NA" test_last_month_segment_absent_when_na
run_test "headroom segment: format" test_headroom_segment_format
run_test "spent today: end-to-end over baseline" test_spent_today_end_to_end_over_baseline
run_test "days left: end-to-end" test_days_left_end_to_end
run_test "headroom segment: fires on low projected pace" test_headroom_segment_fires_when_pace_is_low
run_test "headroom segment: absent when already over pace" test_headroom_segment_absent_when_over_pace
run_test "pace segment: trend up shows 📈" test_pace_segment_trend_up_arrow
run_test "pace segment: trend down shows 📉" test_pace_segment_trend_down_arrow
run_test "pace segment: no trend shows no arrow" test_pace_segment_no_trend_no_arrow

run_test "green under 60% of budget" test_green_under_60_pct
run_test "yellow 60-84% of budget" test_yellow_60_to_84_pct
run_test "orange 85-99% of budget" test_orange_85_to_99_pct
run_test "red at/over 100% of budget" test_red_at_or_over_100_pct
run_test "fresh cache hit skips ccusage call" test_cache_hit_never_calls_ccusage
run_test "cache miss calls ccusage and writes cache" test_cache_miss_calls_ccusage_and_writes_cache
run_test "stale cache triggers refetch" test_stale_cache_triggers_refetch
run_test "ccusage missing from PATH degrades to $0" test_ccusage_missing_falls_back_to_zero
run_test "default monthly budget is 2000 when unset" test_default_budget_is_2000
run_test "count_weekdays: early month (Sep 3)" test_count_weekdays_early_month
run_test "count_weekdays: last day of month" test_count_weekdays_last_day_of_month
run_test "count_weekdays: on a weekend still counts nearest" test_count_weekdays_on_a_weekend_still_counts_nearest
run_test "advance_weekdays skips the weekend" test_advance_weekdays_skips_weekend
run_test "advance_weekdays n=0 returns the from-date" test_advance_weekdays_zero_returns_from_date
run_test "project_exhaustion_date: normal case" test_project_exhaustion_date_normal_case
run_test "project_exhaustion_date: already over budget" test_project_exhaustion_date_already_over_budget
run_test "project_exhaustion_date: avg<=0 fails" test_project_exhaustion_date_zero_avg_fails
run_test "pace segment: under pace is green, no runway" test_pace_segment_under_pace_green_no_runway
run_test "pace segment: over pace is red with runway" test_pace_segment_over_pace_shows_red_and_runway
run_test "pace segment: absent when no weekday data cached" test_pace_segment_absent_when_no_weekday_data

print_summary

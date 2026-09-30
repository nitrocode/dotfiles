#!/bin/bash
set -u

# Test suite for prodsec-oncall-summary.sh
# Usage: bash test-prodsec-oncall-summary.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/prodsec-oncall-summary.sh"

passed=0
failed=0

run_test() {
  local name="$1"
  local test_fn="$2"

  if $test_fn 2>/dev/null; then
    echo "✓ $name"
    ((passed++))
  else
    echo "✗ $name"
    ((failed++))
  fi
}

# Tests

test_script_exists() {
  [[ -f "$SCRIPT" ]]
}

test_script_is_executable() {
  grep -q "#!/bin/bash" "$SCRIPT"
}

test_help_flag() {
  bash "$SCRIPT" --invalid-flag 2>&1 | grep -q "Usage:"
}

test_output_format_contains_sections() {
  # Run with real data - just verify it has the expected sections
  local output=$(bash "$SCRIPT" --start 2026-09-21 --end 2026-09-22 2>&1)
  [[ "$output" == *"Oncall Summary"* ]] && \
  [[ "$output" == *"Slack Activity"* ]] && \
  [[ "$output" == *"GitHub PRs"* ]] && \
  [[ "$output" == *"Jira"* ]] && \
  [[ "$output" == *"Key Themes"* ]]
}

test_date_range_parsing() {
  # Verify the script accepts date range arguments without error
  bash "$SCRIPT" --start 2026-09-15 --end 2026-09-22 >/dev/null 2>&1
  return $?
}

test_days_flag_parsing() {
  # Verify --days flag is accepted
  bash "$SCRIPT" --days 7 >/dev/null 2>&1
  return $?
}

test_output_has_timestamp() {
  local output=$(bash "$SCRIPT" --start 2026-09-21 --end 2026-09-22 2>&1)
  [[ "$output" == *"Generated:"* ]]
}

# Run tests
echo "Running tests..."
run_test "Script exists" test_script_exists
run_test "Script is bash" test_script_is_executable
run_test "Help on invalid flag" test_help_flag
run_test "Output has required sections" test_output_format_contains_sections
run_test "Date range parsing" test_date_range_parsing
run_test "Days flag parsing" test_days_flag_parsing
run_test "Output includes timestamp" test_output_has_timestamp

# Summary
echo ""
echo "Tests: $((passed + failed)) | Passed: $passed | Failed: $failed"
[[ $failed -eq 0 ]] && exit 0 || exit 1

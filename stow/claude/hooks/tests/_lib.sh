#!/bin/bash
# Shared helpers for hook tests. Source from each test-*.sh file.

GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

PASS=0
FAIL=0
FAILED_TESTS=()

HOOKS_DIR="$CLAUDE_CONFIG_DIR/hooks"

assert_decision() {
  local actual="$1" expected="$2"
  local got
  got=$(printf '%s' "$actual" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    return 0
  fi
  printf '    expected decision=%s, got=%s\n' "$expected" "$got" >&2
  printf '    output: %s\n' "$(printf '%s' "$actual" | head -c 200)" >&2
  return 1
}

assert_empty() {
  local actual="$1"
  if [ -z "$actual" ]; then
    return 0
  fi
  printf '    expected empty output, got: %s\n' "$(printf '%s' "$actual" | head -c 200)" >&2
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) return 0;;
    *)
      printf '    expected to contain %s\n    in: %s\n' "$needle" "$(printf '%s' "$haystack" | head -c 200)" >&2
      return 1
      ;;
  esac
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}✓${RESET} %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf "  ${RED}✗${RESET} %s\n" "$name"
  fi
}

print_summary() {
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

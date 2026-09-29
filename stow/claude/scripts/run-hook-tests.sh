#!/bin/bash
# visibility: public
# Run all hook unit tests (~/.claude/hooks/tests/test-*.sh).
# Exit nonzero if any test file fails.
#
# Usage:
#   run-hook-tests.sh           # run all tests
#   run-hook-tests.sh foo bar   # run only test-foo.sh and test-bar.sh

set -u

TESTS_DIR="$CLAUDE_CONFIG_DIR/hooks/tests"

if [ ! -d "$TESTS_DIR" ]; then
  echo "no tests dir: $TESTS_DIR" >&2
  exit 2
fi

files=()
if [ "$#" -eq 0 ]; then
  for f in "$TESTS_DIR"/test-*.sh; do
    [ -f "$f" ] && files+=("$f")
  done
else
  for name in "$@"; do
    f="$TESTS_DIR/test-${name}.sh"
    if [ -f "$f" ]; then
      files+=("$f")
    else
      echo "skip: $f not found" >&2
    fi
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files matched" >&2
  exit 2
fi

OVERALL=0
for f in "${files[@]}"; do
  if bash "$f"; then :; else OVERALL=1; fi
  echo
done

if [ "$OVERALL" -eq 0 ]; then
  echo "all hook tests passed"
else
  echo "one or more hook test files failed"
fi
exit "$OVERALL"

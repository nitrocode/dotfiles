#!/bin/bash
# Unit tests for ~/.claude/hooks/script-test-coverage-warn.sh.
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

HOOK="$CLAUDE_CONFIG_DIR/hooks/script-test-coverage-warn.sh"
echo "test-script-test-coverage-warn.sh:"

# Build a sandbox containing a script + optional sibling test file
# Usage: setup <ext> <line_count> [test_exists:1|0]
setup() {
  SANDBOX=$(mktemp -d)
  SCRIPT_DIR="$SANDBOX/proj/scripts"
  mkdir -p "$SCRIPT_DIR/tests"
  SCRIPT="$SCRIPT_DIR/myscript.$1"
  # Generate $2 non-trivial lines (so the under-20 heuristic doesn't auto-skip).
  printf '#!/bin/bash\nif true; then\n  echo hi\nfi\n' >"$SCRIPT"
  local n=$2
  for ((i=5; i<=n; i++)); do echo "echo line $i" >>"$SCRIPT"; done

  if [ "${3:-0}" = "1" ]; then
    case "$1" in
      py) touch "$SCRIPT_DIR/tests/test_myscript.py" ;;
      *)  touch "$SCRIPT_DIR/tests/test-myscript.sh" ;;
    esac
  fi
}

cleanup() { rm -rf "$SANDBOX"; }

run_hook() {
  local fpath="$1"
  jq -nc --arg p "$fpath" '{tool_input:{file_path:$p}}' | bash "$HOOK"
}

# ---- tests ----

test_non_script_file_is_silent() {
  setup sh 30 1
  local out; out=$(run_hook "$SCRIPT_DIR/notes.md")
  cleanup
  assert_empty "$out"
}

test_script_without_test_warns() {
  setup sh 30 0
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  case "$out" in
    *"systemMessage"*"No test file found"*) return 0;;
    *) printf '    got: %s\n' "$out" >&2; return 1;;
  esac
}

test_script_with_sibling_test_is_silent() {
  setup sh 30 1
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  assert_empty "$out"
}

test_trivial_under_20_lines_is_silent() {
  setup sh 10 0
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  assert_empty "$out"
}

test_test_file_itself_is_silent() {
  setup sh 30 1
  local out; out=$(run_hook "$SCRIPT_DIR/tests/test-myscript.sh")
  cleanup
  assert_empty "$out"
}

test_file_in_tests_dir_is_silent() {
  setup sh 30 0
  # Place a non-test-named file inside a tests/ dir; should still skip
  local f="$SCRIPT_DIR/tests/helper.sh"
  cp "$SCRIPT" "$f"
  local out; out=$(run_hook "$f")
  cleanup
  assert_empty "$out"
}

test_vendored_path_is_silent() {
  setup sh 30 0
  local nm="$SANDBOX/node_modules/foo/script.sh"
  mkdir -p "$(dirname "$nm")"
  cp "$SCRIPT" "$nm"
  local out; out=$(run_hook "$nm")
  cleanup
  assert_empty "$out"
}

test_python_script_with_test_is_silent() {
  setup py 30 1
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  assert_empty "$out"
}

test_python_script_without_test_warns_with_correct_path() {
  setup py 30 0
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  case "$out" in
    *"tests/test_myscript.py"*) return 0;;
    *) printf '    got: %s\n' "$out" >&2; return 1;;
  esac
}

test_init_py_is_silent() {
  setup py 30 0
  local f="$SCRIPT_DIR/__init__.py"
  cp "$SCRIPT" "$f"
  local out; out=$(run_hook "$f")
  cleanup
  assert_empty "$out"
}

test_conftest_py_is_silent() {
  setup py 30 0
  local f="$SCRIPT_DIR/conftest.py"
  cp "$SCRIPT" "$f"
  local out; out=$(run_hook "$f")
  cleanup
  assert_empty "$out"
}

test_nonexistent_file_is_silent() {
  local out; out=$(run_hook "/nonexistent/path/foo.sh")
  assert_empty "$out"
}

test_empty_file_path_is_silent() {
  local out; out=$(echo '{}' | bash "$HOOK")
  assert_empty "$out"
}

test_test_at_parent_dir_tests_is_found() {
  setup sh 30 0
  # Place test one level up at parent/tests/
  local parent_tests="$SANDBOX/proj/tests"
  mkdir -p "$parent_tests"
  touch "$parent_tests/test-myscript.sh"
  local out; out=$(run_hook "$SCRIPT")
  cleanup
  assert_empty "$out"
}

run_test "non-script file is silent"                    test_non_script_file_is_silent
run_test "script without test warns"                    test_script_without_test_warns
run_test "script with sibling test is silent"           test_script_with_sibling_test_is_silent
run_test "trivial <20 line script is silent"            test_trivial_under_20_lines_is_silent
run_test "test file itself is silent"                   test_test_file_itself_is_silent
run_test "file inside tests/ dir is silent"             test_file_in_tests_dir_is_silent
run_test "vendored path (node_modules) is silent"       test_vendored_path_is_silent
run_test "Python script with test is silent"            test_python_script_with_test_is_silent
run_test "Python script without test warns w/.py path"  test_python_script_without_test_warns_with_correct_path
run_test "__init__.py is silent"                        test_init_py_is_silent
run_test "conftest.py is silent"                        test_conftest_py_is_silent
run_test "nonexistent file is silent"                   test_nonexistent_file_is_silent
run_test "empty file_path is silent"                    test_empty_file_path_is_silent
run_test "test at parent/tests/ is discovered"          test_test_at_parent_dir_tests_is_found

print_summary

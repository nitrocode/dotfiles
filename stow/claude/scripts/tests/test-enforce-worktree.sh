#!/usr/bin/env bash
# Unit tests for enforce-worktree.sh
# Run: bash $CLAUDE_CONFIG_DIR/scripts/tests/test-enforce-worktree.sh
set -uo pipefail

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/enforce-worktree.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0

run_test() {
  local name="$1"
  local expected_block="$2" # "block" or "allow"
  local input="$3"

  local output
  output=$(printf '%s' "$input" | bash "$SCRIPT" 2>&1)

  if [ "$expected_block" = "block" ]; then
    if printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
      echo "PASS: $name"
      pass=$((pass + 1))
    else
      echo "FAIL: $name (expected block, got: $output)"
      fail=$((fail + 1))
    fi
  else
    if [ -z "$output" ]; then
      echo "PASS: $name"
      pass=$((pass + 1))
    else
      echo "FAIL: $name (expected allow/no output, got: $output)"
      fail=$((fail + 1))
    fi
  fi
}

make_repo() {
  local repo_dir="$1"
  local default_branch="$2"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q -b "$default_branch"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" config user.name "Test"
  echo "content" > "$repo_dir/file.txt"
  git -C "$repo_dir" add file.txt
  git -C "$repo_dir" commit -q -m "init"
}

# --- Test 1: on main, no origin remote configured -> blocked via local main fallback ---
repo1="$SANDBOX/repo1"
make_repo "$repo1" "main"
run_test "blocks edit on local main (no origin)" "block" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo1/file.txt\"}}"

# --- Test 2: on a feature branch -> allowed ---
repo2="$SANDBOX/repo2"
make_repo "$repo2" "main"
git -C "$repo2" checkout -q -b feature/test
run_test "allows edit on feature branch" "allow" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo2/file.txt\"}}"

# --- Test 3: on master (local fallback) -> blocked ---
repo3="$SANDBOX/repo3"
make_repo "$repo3" "master"
run_test "blocks edit on local master (no origin)" "block" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo3/file.txt\"}}"

# --- Test 4: with origin/HEAD pointing at main, on main -> blocked ---
repo4_remote="$SANDBOX/repo4-remote.git"
git init -q --bare "$repo4_remote"
repo4="$SANDBOX/repo4"
make_repo "$repo4" "main"
git -C "$repo4" remote add origin "$repo4_remote"
git -C "$repo4" push -q -u origin main
git -C "$repo4" remote set-head origin main
run_test "blocks edit on main with origin/HEAD" "block" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo4/file.txt\"}}"

# --- Test 5: not a git repo at all -> allowed ---
plain_dir="$SANDBOX/plain"
mkdir -p "$plain_dir"
echo "x" > "$plain_dir/file.txt"
run_test "allows edit outside any git repo" "allow" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$plain_dir/file.txt\"}}"

# --- Test 6: no file_path in input -> allowed ---
run_test "allows when tool_input has no file_path" "allow" \
  '{"tool_name":"Edit","tool_input":{}}'

# --- Test 7: worktree checkout on a feature branch off repo4 -> allowed ---
git -C "$repo4" worktree add -q -b feature/wt "$SANDBOX/repo4-wt" origin/main
run_test "allows edit in worktree on feature branch" "allow" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SANDBOX/repo4-wt/file.txt\"}}"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/bin/bash
# Tests for lint-on-write.sh
# Stubs gofmt/go/terraform/yamllint/shellcheck via PATH so results are
# deterministic regardless of what's actually installed on this machine.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS_DIR/lint-on-write.sh"

PASS=0
FAIL=0
FAILED=()

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin"
}
teardown_sandbox() {
  rm -rf "$SANDBOX"
}

invoke_hook() {
  local file="$1"
  printf '{"tool_input":{"file_path":"%s"}}' "$file" | PATH="$SANDBOX/bin:$PATH" bash "$HOOK" 2>&1
}

# Minimal PATH with no linters on it at all (not even real ones from the host),
# used by the "tool missing" tests. Only jq needs to survive since it's a hard
# dependency of the hook; cat/echo/case are shell builtins.
invoke_hook_no_linters() {
  local file="$1"
  ln -sf "$(command -v jq)" "$SANDBOX/bin/jq"
  printf '{"tool_input":{"file_path":"%s"}}' "$file" | PATH="$SANDBOX/bin:/usr/bin:/bin" bash "$HOOK" 2>&1
}

write_stub() {
  # write_stub <name> <stdout-to-print-or-empty>
  local name="$1" out="$2"
  cat > "$SANDBOX/bin/$name" <<EOF
#!/bin/bash
if [ -n "$out" ]; then echo "$out"; fi
exit 0
EOF
  chmod +x "$SANDBOX/bin/$name"
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

# --------------------------------------------------------------------------

test_go_warns_when_gofmt_reformats() {
  setup_sandbox
  write_stub gofmt "$SANDBOX/dirty.go"
  write_stub go ""
  local f="$SANDBOX/dirty.go"
  echo "package main" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"gofmt reformatted"* ]]
}

test_go_warns_on_vet_issue() {
  setup_sandbox
  write_stub gofmt ""
  write_stub go "vet: unreachable code"
  local f="$SANDBOX/bad_vet.go"
  echo "package main" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"go vet issues"* ]] && [[ "$out" == *"unreachable code"* ]]
}

test_go_silent_when_clean() {
  setup_sandbox
  write_stub gofmt ""
  write_stub go ""
  local f="$SANDBOX/clean.go"
  echo "package main" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_go_silent_when_tools_missing() {
  setup_sandbox
  local f="$SANDBOX/no_tools.go"
  echo "package main" > "$f"
  local out
  out=$(invoke_hook_no_linters "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_yaml_warns_on_lint_issue() {
  setup_sandbox
  write_stub yamllint "1:1 error too many spaces (colons)"
  local f="$SANDBOX/bad.yaml"
  echo "foo:   bar" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"yamllint on"* ]] && [[ "$out" == *"too many spaces"* ]]
}

test_yaml_silent_when_clean() {
  setup_sandbox
  write_stub yamllint ""
  local f="$SANDBOX/clean.yaml"
  echo "foo: bar" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_yaml_silent_when_yamllint_missing() {
  setup_sandbox
  local f="$SANDBOX/no_tool.yaml"
  echo "foo: bar" > "$f"
  local out
  out=$(invoke_hook_no_linters "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

# Regression coverage for the pre-existing branches, unaffected by this change.

test_shell_warns_on_shellcheck_issue() {
  setup_sandbox
  write_stub shellcheck "SC2086 (info): Double quote to prevent globbing"
  local f="$SANDBOX/bad.sh"
  echo 'echo $foo' > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"shellcheck on"* ]]
}

test_tf_warns_on_fmt_drift() {
  setup_sandbox
  write_stub terraform "diff --- a/main.tf"
  local f="$SANDBOX/main.tf"
  echo 'resource "x" "y" {}' > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ "$out" == *"terraform fmt drift"* ]]
}

test_nonexistent_file_is_silent() {
  setup_sandbox
  local out
  out=$(invoke_hook "$SANDBOX/does-not-exist.go")
  teardown_sandbox
  [[ -z "$out" ]]
}

test_unmatched_extension_is_silent() {
  setup_sandbox
  write_stub gofmt "should not run"
  local f="$SANDBOX/notes.py"
  echo "x = 1" > "$f"
  local out
  out=$(invoke_hook "$f")
  teardown_sandbox
  [[ -z "$out" ]]
}

# --------------------------------------------------------------------------

run_test "go: warns when gofmt reformats" test_go_warns_when_gofmt_reformats
run_test "go: warns on vet issue" test_go_warns_on_vet_issue
run_test "go: silent when clean" test_go_silent_when_clean
run_test "go: silent when tools missing" test_go_silent_when_tools_missing
run_test "yaml: warns on lint issue" test_yaml_warns_on_lint_issue
run_test "yaml: silent when clean" test_yaml_silent_when_clean
run_test "yaml: silent when yamllint missing" test_yaml_silent_when_yamllint_missing
run_test "shell: warns on shellcheck issue (regression)" test_shell_warns_on_shellcheck_issue
run_test "tf: warns on fmt drift (regression)" test_tf_warns_on_fmt_drift
run_test "silent on nonexistent file" test_nonexistent_file_is_silent
run_test "silent on unmatched extension" test_unmatched_extension_is_silent

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed: %s\n' "${FAILED[*]}"
  exit 1
fi
exit 0

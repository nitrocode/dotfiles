#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-config-change-context-nudge.sh:"

HOOK="$HOOKS_DIR/config-change-context-nudge.sh"

assert_nudges() {
  local actual="$1"
  local body
  body=$(printf '%s' "$actual" | jq -r '.systemMessage // ""' 2>/dev/null)
  case "$body" in
    *"/context"*) return 0;;
    *)
      printf '    expected a /context nudge, got: %s\n' "$(printf '%s' "$body" | head -c 200)" >&2
      return 1
      ;;
  esac
}

setup_sandbox_home() {
  local sandbox
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/.claude/skills/example"
  echo '{"env":{}}' > "$sandbox/.claude/settings.json"
  echo '# CLAUDE.md' > "$sandbox/.claude/CLAUDE.md"
  printf 'name: example\ndescription: an example skill\n' > "$sandbox/.claude/skills/example/SKILL.md"
  echo "$sandbox"
}

run_in_sandbox() {
  local sandbox="$1"
  HOME="$sandbox" CLAUDE_CONFIG_DIR="$sandbox/.claude" bash "$HOOK"
}

test_no_prior_hash_nudges_and_writes() {
  local sandbox; sandbox=$(setup_sandbox_home)
  local out; out=$(run_in_sandbox "$sandbox")
  assert_nudges "$out" || { rm -rf "$sandbox"; return 1; }
  [ -s "$sandbox/.claude/state/config-hash.txt" ] || { echo "    expected hash file to be written" >&2; rm -rf "$sandbox"; return 1; }
  rm -rf "$sandbox"
}

test_unchanged_config_silent() {
  local sandbox; sandbox=$(setup_sandbox_home)
  run_in_sandbox "$sandbox" > /dev/null
  local out; out=$(run_in_sandbox "$sandbox")
  assert_empty "$out"
  local rc=$?
  rm -rf "$sandbox"
  return $rc
}

test_changed_config_nudges_and_updates_hash() {
  local sandbox; sandbox=$(setup_sandbox_home)
  run_in_sandbox "$sandbox" > /dev/null
  local old_hash; old_hash=$(cat "$sandbox/.claude/state/config-hash.txt")
  echo '# CLAUDE.md changed' > "$sandbox/.claude/CLAUDE.md"
  local out; out=$(run_in_sandbox "$sandbox")
  assert_nudges "$out" || { rm -rf "$sandbox"; return 1; }
  local new_hash; new_hash=$(cat "$sandbox/.claude/state/config-hash.txt")
  if [ "$old_hash" = "$new_hash" ]; then
    echo "    expected hash to change" >&2
    rm -rf "$sandbox"
    return 1
  fi
  rm -rf "$sandbox"
}

run_test "no prior hash -> nudges, writes hash" test_no_prior_hash_nudges_and_writes
run_test "unchanged config -> silent" test_unchanged_config_silent
run_test "changed config -> nudges, updates hash" test_changed_config_nudges_and_updates_hash

print_summary

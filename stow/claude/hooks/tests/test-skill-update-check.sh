#!/bin/bash
set -u
# shellcheck source=_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

echo "test-skill-update-check.sh:"

HOOK="$HOOKS_DIR/skill-update-check.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

setup_sandbox() {
  mkdir -p "$SANDBOX/.claude/skills/my-personal-skill"
  mkdir -p "$SANDBOX/.claude/plugins/cache/some-marketplace/single-version-plugin/1.0.0"
  mkdir -p "$SANDBOX/.claude/plugins/cache/some-marketplace/multi-version-plugin/1.0.0"
  mkdir -p "$SANDBOX/.claude/plugins/cache/some-marketplace/multi-version-plugin/1.2.0"
  mkdir -p "$SANDBOX/.claude/plugins/cache/some-marketplace/multi-version-plugin/1.10.0"
}

run_with() {
  local skill="$1"
  local input
  input=$(jq -nc --arg skill "$skill" '{tool_input:{skill:$skill}}')
  printf '%s' "$input" | HOME="$SANDBOX" bash "$HOOK"
}

setup_sandbox

test_personal_skill_not_flagged() {
  local out
  out=$(run_with "my-personal-skill")
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // "none"')
  [ "$ctx" = "none" ]
}

test_plugin_single_version_flagged_as_shared() {
  local out
  out=$(run_with "single-version-plugin:some-skill")
  assert_contains "$out" "shared/upstream"
}

test_plugin_single_version_no_update_note() {
  local out
  out=$(run_with "single-version-plugin:some-skill")
  case "$out" in
    *"cached versions found"*) return 1 ;;
    *) return 0 ;;
  esac
}

test_plugin_multi_version_flagged_with_count() {
  local out
  out=$(run_with "multi-version-plugin:some-skill")
  assert_contains "$out" "3 cached versions found"
}

test_plugin_multi_version_reports_correct_semver_max() {
  local out
  out=$(run_with "multi-version-plugin:some-skill")
  assert_contains "$out" "newest is 1.10.0"
}

test_unknown_bare_skill_not_flagged() {
  local out
  out=$(run_with "some-builtin-skill")
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // "none"')
  [ "$ctx" = "none" ]
}

test_missing_skill_input_does_not_crash() {
  local out
  out=$(printf '%s' '{"tool_input":{}}' | HOME="$SANDBOX" bash "$HOOK")
  [ "$out" = "{}" ]
}

run_test "personal skill is not flagged" test_personal_skill_not_flagged
run_test "plugin skill (single cached version) flagged as shared/upstream" test_plugin_single_version_flagged_as_shared
run_test "plugin skill (single cached version) has no update note" test_plugin_single_version_no_update_note
run_test "plugin skill (multi cached version) flagged with version count" test_plugin_multi_version_flagged_with_count
run_test "plugin skill (multi cached version) reports correct semver max" test_plugin_multi_version_reports_correct_semver_max
run_test "unrecognized bare skill (built-in) is not flagged" test_unknown_bare_skill_not_flagged
run_test "missing skill input does not crash" test_missing_skill_input_does_not_crash

print_summary

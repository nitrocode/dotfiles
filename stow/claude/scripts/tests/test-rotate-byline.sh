#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/rotate-byline.sh.
# Isolates by pointing HOME at a temp dir (the script reads $CLAUDE_CONFIG_DIR/settings.json).
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/rotate-byline.sh"
echo "test-rotate-byline.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/.claude" "$SANDBOX/bin"
  SETTINGS="$SANDBOX/.claude/settings.json"
  ORIG_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
  export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
  # Mock python3 — Claude Code sandbox blocks nested-bash python3 on /var/folders paths,
  # which would mask the script's real behavior. The mock validates JSON via jq instead.
  cat >"$SANDBOX/bin/python3" <<'EOF'
#!/bin/bash
# Only intercept `python3 -m json.tool <file>`; passthrough everything else.
if [ "$1" = "-m" ] && [ "$2" = "json.tool" ] && [ -n "${3:-}" ]; then
  jq -e . "$3" >/dev/null 2>&1
  exit $?
fi
exec /usr/bin/env -i PATH="/usr/local/bin:/usr/bin:/bin" python3 "$@"
EOF
  chmod +x "$SANDBOX/bin/python3"
  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"
  export HOME="$SANDBOX"
}

teardown_sandbox() {
  export HOME="$REAL_HOME"
  export PATH="$ORIG_PATH"
  export CLAUDE_CONFIG_DIR="$ORIG_CLAUDE_CONFIG_DIR"
  rm -rf "$SANDBOX"
}

write_settings() {
  printf '%s' "$1" >"$SETTINGS"
}

run_script() {
  bash "$SCRIPT"
}

# ---- tests ----

test_missing_settings_exits_zero() {
  setup_sandbox
  run_script
  local rc=$?
  teardown_sandbox
  [ "$rc" -eq 0 ]
}

test_updates_both_byline_fields() {
  setup_sandbox
  write_settings '{"byline":{"commit":"old","pr":"old"}}'
  run_script
  local commit pr
  commit=$(jq -r '.byline.commit' "$SETTINGS")
  pr=$(jq -r '.byline.pr' "$SETTINGS")
  teardown_sandbox
  [ "$commit" != "old" ] && [ "$pr" != "old" ] \
    && [ -n "$commit" ] && [ -n "$pr" ]
}

test_clears_attribution_to_empty_strings() {
  setup_sandbox
  write_settings '{"attribution":{"commit":"old","pr":"old"}}'
  run_script
  local commit pr
  commit=$(jq -r '.attribution.commit' "$SETTINGS")
  pr=$(jq -r '.attribution.pr' "$SETTINGS")
  teardown_sandbox
  [ "$commit" = "" ] && [ "$pr" = "" ]
}

test_output_is_valid_json() {
  setup_sandbox
  write_settings '{"byline":{"commit":"old","pr":"old"},"otherKey":"value"}'
  run_script
  local valid=1
  jq -e . "$SETTINGS" >/dev/null 2>&1 || valid=0
  teardown_sandbox
  [ "$valid" -eq 1 ]
}

test_preserves_unrelated_keys() {
  setup_sandbox
  write_settings '{"byline":{"commit":"old","pr":"old"},"theme":"dark","permissions":{"allow":["Read"]}}'
  run_script
  local theme allow
  theme=$(jq -r '.theme' "$SETTINGS")
  allow=$(jq -r '.permissions.allow[0]' "$SETTINGS")
  teardown_sandbox
  [ "$theme" = "dark" ] && [ "$allow" = "Read" ]
}

test_commit_has_no_unsubstituted_placeholders() {
  setup_sandbox
  write_settings '{}'
  run_script
  local commit; commit=$(jq -r '.byline.commit' "$SETTINGS")
  teardown_sandbox
  case "$commit" in
    *"%S%"*|*"%E%"*) return 1;;
    *) return 0;;
  esac
}

test_pr_has_no_unsubstituted_placeholders() {
  setup_sandbox
  write_settings '{}'
  run_script
  local pr; pr=$(jq -r '.byline.pr' "$SETTINGS")
  teardown_sandbox
  case "$pr" in
    *"%E%"*|*"%S%"*) return 1;;
    *) return 0;;
  esac
}

test_corrupted_settings_leaves_file_untouched() {
  setup_sandbox
  printf 'this is not json' >"$SETTINGS"
  local before; before=$(cat "$SETTINGS")
  run_script
  local after; after=$(cat "$SETTINGS")
  local tmp_present=0
  [ -e "$SETTINGS.rotate.tmp" ] && tmp_present=1
  teardown_sandbox
  [ "$before" = "$after" ] && [ "$tmp_present" -eq 0 ]
}

test_commit_byline_is_co_authored_by_format() {
  setup_sandbox
  write_settings '{}'
  run_script
  local commit; commit=$(jq -r '.byline.commit' "$SETTINGS")
  teardown_sandbox
  case "$commit" in
    "Co-Authored-By: "*"<noreply@anthropic.com>") return 0;;
    *) return 1;;
  esac
}

test_idempotent_under_repeat_runs() {
  setup_sandbox
  write_settings '{"byline":{"commit":"old","pr":"old"}}'
  for _ in 1 2 3 4 5; do run_script; done
  local valid=1
  jq -e '.byline.commit and .byline.pr' "$SETTINGS" >/dev/null 2>&1 || valid=0
  teardown_sandbox
  [ "$valid" -eq 1 ]
}

run_test "missing settings.json → exit 0"            test_missing_settings_exits_zero
run_test "updates both byline fields"                 test_updates_both_byline_fields
run_test "clears attribution to empty strings"        test_clears_attribution_to_empty_strings
run_test "result is valid JSON"                       test_output_is_valid_json
run_test "preserves unrelated keys"                   test_preserves_unrelated_keys
run_test "commit has no %S% / %E% leftovers"          test_commit_has_no_unsubstituted_placeholders
run_test "pr has no %S% / %E% leftovers"              test_pr_has_no_unsubstituted_placeholders
run_test "corrupt input leaves file untouched"        test_corrupted_settings_leaves_file_untouched
run_test "commit matches Co-Authored-By format"       test_commit_byline_is_co_authored_by_format
run_test "5 repeat runs still produce valid JSON"     test_idempotent_under_repeat_runs

print_summary

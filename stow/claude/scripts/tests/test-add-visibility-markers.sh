#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/add-visibility-markers.sh.
# Stubs $HOME with a minimal Claude config tree containing one file per type
# the script handles (.sh, .md, .json, no-extension git hook).
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
REAL_CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/add-visibility-markers.sh"
echo "test-add-visibility-markers.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/.claude/scripts" \
           "$SANDBOX/.claude/git-hooks" \
           "$SANDBOX/.claude/prompts/templates" \
           "$SANDBOX/bin"

  # Mock python3 — Claude Code sandbox blocks nested-bash python3 with HOME
  # override on /var/folders paths. The script's only python3 use is to set
  # a _visibility key in a JSON file; substitute with jq.
  cat >"$SANDBOX/bin/python3" <<'EOF'
#!/bin/bash
if [ "$1" = "-c" ]; then
  code="$2"
  path=$(printf '%s' "$code" | grep -oE "p = '[^']+'" | head -1 | sed -E "s/p = '(.+)'/\1/")
  vis=$(printf '%s' "$code" | grep -oE "_visibility'\] = '[^']+'|'_visibility': '[^']+'" | head -1 | grep -oE "'(public|internal)'$" | tr -d "'")
  if [ -n "$path" ] && [ -n "$vis" ] && [ -f "$path" ]; then
    tmp=$(mktemp)
    if printf '%s' "$code" | grep -q "new.update(data)"; then
      jq --arg v "$vis" '{"_visibility": $v} + .' "$path" >"$tmp" && mv "$tmp" "$path"
    else
      jq --arg v "$vis" '._visibility = $v' "$path" >"$tmp" && mv "$tmp" "$path"
    fi
    exit 0
  fi
  exit 1
fi
exit 0
EOF
  chmod +x "$SANDBOX/bin/python3"
  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"

  # .sh with shebang (mapped to public)
  cat >"$SANDBOX/.claude/scripts/aws-auth-refresh.sh" <<'EOF'
#!/usr/bin/env bash
echo hi
EOF

  # .md without frontmatter (public) — goes via HTML comment branch
  echo "# RTK" >"$SANDBOX/.claude/RTK.md"

  # .json (public)
  echo '{"bar":"bar"}' >"$SANDBOX/.claude/prompts/templates/extraction-skill-v1.0.0.meta.json"

  # No-extension shell script with shebang (public)
  printf '#!/bin/bash\necho hook\n' >"$SANDBOX/.claude/git-hooks/prepare-commit-msg"

  # .md without frontmatter (internal)
  echo "# CLAUDE" >"$SANDBOX/.claude/CLAUDE.md"

  export HOME="$SANDBOX"
  # The script resolves its root from CLAUDE_CONFIG_DIR, so sandbox that too
  # or apply-mode tests rewrite the real config dir.
  export CLAUDE_CONFIG_DIR="$SANDBOX/.claude"
}

teardown_sandbox() {
  export HOME="$REAL_HOME"
  export CLAUDE_CONFIG_DIR="$REAL_CLAUDE_CONFIG_DIR"
  export PATH="$ORIG_PATH"
  rm -rf "$SANDBOX"
}

run_script() {
  bash "$SCRIPT" "$@"
}

# ---- tests ----

test_check_mode_does_not_modify_files() {
  setup_sandbox
  local before_hash; before_hash=$(find "$SANDBOX/.claude" -type f -exec shasum {} \; | shasum)
  run_script --check >/dev/null
  local after_hash; after_hash=$(find "$SANDBOX/.claude" -type f -exec shasum {} \; | shasum)
  teardown_sandbox
  [ "$before_hash" = "$after_hash" ]
}

test_apply_adds_visibility_to_sh_file() {
  setup_sandbox
  run_script >/dev/null
  local content; content=$(cat "$SANDBOX/.claude/scripts/aws-auth-refresh.sh")
  teardown_sandbox
  case "$content" in
    *"# visibility: public"*) return 0;;
    *) printf '    got: %s\n' "$content" >&2; return 1;;
  esac
}

test_sh_marker_inserted_after_shebang() {
  setup_sandbox
  run_script >/dev/null
  local line2; line2=$(sed -n '2p' "$SANDBOX/.claude/scripts/aws-auth-refresh.sh")
  teardown_sandbox
  [ "$line2" = "# visibility: public" ]
}

test_md_without_frontmatter_gets_html_comment() {
  setup_sandbox
  run_script >/dev/null
  local content; content=$(cat "$SANDBOX/.claude/RTK.md")
  teardown_sandbox
  # Line 1 is a heading, so the script keeps it first and puts the marker on line 3.
  case "$content" in
    "# RTK"$'\n\n'"<!-- visibility: public -->"*) return 0;;
    *) printf '    got: %s\n' "$content" >&2; return 1;;
  esac
}

test_json_gets_visibility_key() {
  setup_sandbox
  run_script >/dev/null
  local vis; vis=$(jq -r '._visibility' "$SANDBOX/.claude/prompts/templates/extraction-skill-v1.0.0.meta.json")
  teardown_sandbox
  [ "$vis" = "public" ]
}

test_json_preserves_existing_keys() {
  setup_sandbox
  run_script >/dev/null
  local bar; bar=$(jq -r '.bar' "$SANDBOX/.claude/prompts/templates/extraction-skill-v1.0.0.meta.json")
  teardown_sandbox
  [ "$bar" = "bar" ]
}

test_no_extension_script_marker_after_shebang() {
  setup_sandbox
  run_script >/dev/null
  local line2; line2=$(sed -n '2p' "$SANDBOX/.claude/git-hooks/prepare-commit-msg")
  teardown_sandbox
  [ "$line2" = "# visibility: public" ]
}

test_internal_files_get_internal_marker() {
  setup_sandbox
  run_script >/dev/null
  local content; content=$(cat "$SANDBOX/.claude/CLAUDE.md")
  teardown_sandbox
  case "$content" in
    "# CLAUDE"$'\n\n'"<!-- visibility: internal -->"*) return 0;;
    *) return 1;;
  esac
}

test_rerun_is_idempotent() {
  setup_sandbox
  run_script >/dev/null
  local first; first=$(shasum "$SANDBOX/.claude/scripts/aws-auth-refresh.sh" \
                       "$SANDBOX/.claude/RTK.md" \
                       "$SANDBOX/.claude/CLAUDE.md")
  run_script >/dev/null
  local second; second=$(shasum "$SANDBOX/.claude/scripts/aws-auth-refresh.sh" \
                         "$SANDBOX/.claude/RTK.md" \
                         "$SANDBOX/.claude/CLAUDE.md")
  teardown_sandbox
  [ "$first" = "$second" ]
}

test_summary_counts_new_markers() {
  setup_sandbox
  local out; out=$(run_script)
  teardown_sandbox
  # 5 staged files all need new markers
  case "$out" in
    *"5 new markers"*) return 0;;
    *) printf '    got: %s\n' "$out" >&2; return 1;;
  esac
}

test_summary_counts_missing_sources() {
  setup_sandbox
  local out; out=$(run_script)
  teardown_sandbox
  # Many files in FILES mapping aren't staged → missing-source > 0
  case "$out" in
    *"missing-source"*)
      local n; n=$(echo "$out" | grep -oE '[0-9]+ missing-source' | grep -oE '[0-9]+')
      [ "${n:-0}" -gt 0 ]
      ;;
    *) return 1;;
  esac
}

test_mismatched_marker_is_updated() {
  setup_sandbox
  # Pre-seed CLAUDE.md with a 'public' marker — script should flip it to 'internal'
  printf '<!-- visibility: public -->\n\n# CLAUDE\n' >"$SANDBOX/.claude/CLAUDE.md"
  run_script >/dev/null
  local content; content=$(head -1 "$SANDBOX/.claude/CLAUDE.md")
  teardown_sandbox
  [ "$content" = "<!-- visibility: internal -->" ]
}

run_test "--check mode does not modify files"        test_check_mode_does_not_modify_files
run_test "apply adds visibility to .sh file"         test_apply_adds_visibility_to_sh_file
run_test ".sh marker inserted after shebang"         test_sh_marker_inserted_after_shebang
run_test ".md without frontmatter gets HTML comment" test_md_without_frontmatter_gets_html_comment
run_test ".json gets _visibility key"                test_json_gets_visibility_key
run_test ".json preserves existing keys"             test_json_preserves_existing_keys
run_test "no-extension script: marker after shebang" test_no_extension_script_marker_after_shebang
run_test "internal files get internal marker"        test_internal_files_get_internal_marker
run_test "rerun is idempotent"                       test_rerun_is_idempotent
run_test "summary counts 5 new markers"              test_summary_counts_new_markers
run_test "summary counts missing-source files"       test_summary_counts_missing_sources
run_test "mismatched marker is updated"              test_mismatched_marker_is_updated

print_summary

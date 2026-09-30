#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/pr-gif-comment.sh.
# Mocks op/curl/gh via a temp PATH override to avoid network and 1Password calls.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

SCRIPT="$CLAUDE_CONFIG_DIR/scripts/pr-gif-comment.sh"
echo "test-pr-gif-comment.sh:"

setup_mocks() {
  MOCKDIR=$(mktemp -d)
  CALLS="$MOCKDIR/calls.log"
  : >"$CALLS"

  # op mock — emits the configured api_key (or fails if OP_FAIL=1)
  cat >"$MOCKDIR/op" <<'EOF'
#!/bin/bash
echo "op $*" >>"$CALLS"
if [ "${OP_FAIL:-0}" = "1" ]; then exit 1; fi
echo "${OP_API_KEY:-fake-key}"
EOF

  # curl mock — emits a Giphy-shaped JSON response (or fails if CURL_FAIL=1)
  cat >"$MOCKDIR/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$CALLS"
if [ "${CURL_FAIL:-0}" = "1" ]; then exit 22; fi
if [ "${CURL_EMPTY:-0}" = "1" ]; then echo '{"data":{}}'; exit 0; fi
echo '{"data":{"images":{"original":{"url":"https://media.giphy.com/test.gif"}}}}'
EOF

  # gh mock — records args, returns JSON {body, title} for `pr view`,
  # fails on `pr edit` if GH_FAIL=1
  cat >"$MOCKDIR/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$CALLS"
case "$*" in
  "pr view "*)
    body="${EXISTING_BODY:-existing body line 1}"
    title="${PR_TITLE:-chore: some change}"
    jq -nc --arg b "$body" --arg t "$title" '{body:$b,title:$t}'
    exit 0
    ;;
  "pr edit "*)
    if [ "${GH_FAIL:-0}" = "1" ]; then exit 1; fi
    exit 0
    ;;
esac
if [ "${GH_FAIL:-0}" = "1" ]; then exit 1; fi
EOF

  chmod +x "$MOCKDIR/op" "$MOCKDIR/curl" "$MOCKDIR/gh"
  export PATH="$MOCKDIR:$PATH"
  export CALLS
}

teardown_mocks() {
  unset OP_FAIL CURL_FAIL CURL_EMPTY GH_FAIL OP_API_KEY EXISTING_BODY PR_TITLE GIPHY_TAG GIPHY_RATING
  rm -rf "$MOCKDIR"
}

run_script() {
  local payload="$1"
  printf '%s' "$payload" | bash "$SCRIPT"
}

# Build a payload with a given stdout value
payload_with_stdout() {
  jq -nc --arg s "$1" '{tool_name:"Bash",tool_input:{command:"gh pr create"},tool_response:{stdout:$s,output:""}}'
}

# Extract the tag from the recorded curl call. Curl args contain `tag=<value>&...`.
extract_tag_from_calls() {
  grep -oE 'tag=[^&]+' "$CALLS" | head -1 | sed 's/^tag=//'
}

# Extract the rating from the recorded curl call.
extract_rating_from_calls() {
  grep -oE 'rating=[^ ]+' "$CALLS" | head -1 | sed 's/^rating=//'
}

# ---- tests ----

test_no_pr_url_skips_silently() {
  setup_mocks
  local out; out=$(run_script "$(payload_with_stdout 'no url here')")
  local rc=$?
  teardown_mocks
  [ "$rc" -eq 0 ] && assert_empty "$out"
}

test_pr_url_triggers_full_chain() {
  setup_mocks
  run_script "$(payload_with_stdout 'created https://github.com/acme/foo/pull/42 done')" >/dev/null
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] \
    && assert_contains "$calls" "op read op://Employee/GIPHY/api key rb-cli" \
    && assert_contains "$calls" "api.giphy.com/v1/gifs/random" \
    && assert_contains "$calls" "gh pr view https://github.com/acme/foo/pull/42 --json body,title" \
    && assert_contains "$calls" "gh pr edit https://github.com/acme/foo/pull/42 --body"
}

test_appended_body_preserves_existing_content() {
  setup_mocks
  EXISTING_BODY="## what$'\n\n'- some change" run_script "$(payload_with_stdout 'https://github.com/o/r/pull/7')" >/dev/null
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  assert_contains "$calls" "![](https://media.giphy.com/test.gif)"
}

test_op_failure_short_circuits() {
  setup_mocks
  OP_FAIL=1 run_script "$(payload_with_stdout 'https://github.com/o/r/pull/1')" >/dev/null
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] && case "$calls" in *"gh pr edit"*) return 1;; *) return 0;; esac
}

test_giphy_empty_response_skips_post() {
  setup_mocks
  CURL_EMPTY=1 run_script "$(payload_with_stdout 'https://github.com/o/r/pull/2')" >/dev/null
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] && case "$calls" in *"gh pr edit"*) return 1;; *) return 0;; esac
}

test_curl_failure_skips_post() {
  setup_mocks
  CURL_FAIL=1 run_script "$(payload_with_stdout 'https://github.com/o/r/pull/3')" >/dev/null
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] && case "$calls" in *"gh pr edit"*) return 1;; *) return 0;; esac
}

test_gh_failure_is_swallowed() {
  setup_mocks
  GH_FAIL=1 run_script "$(payload_with_stdout 'https://github.com/o/r/pull/4')" >/dev/null
  local rc=$?
  teardown_mocks
  [ "$rc" -eq 0 ]
}

test_picks_first_url_when_multiple() {
  setup_mocks
  run_script "$(payload_with_stdout 'first https://github.com/a/b/pull/1 second https://github.com/c/d/pull/2')" >/dev/null
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  assert_contains "$calls" "gh pr edit https://github.com/a/b/pull/1"
}

test_ignores_non_pr_github_urls() {
  setup_mocks
  local out; out=$(run_script "$(payload_with_stdout 'see https://github.com/o/r/issues/5')")
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] && case "$calls" in *"gh pr edit"*) return 1;; *) return 0;; esac
}

# Defensive command filter: hook fires on every Bash, so the script must
# self-filter on tool_input.command.
test_non_pr_create_command_with_url_is_ignored() {
  setup_mocks
  local payload
  payload=$(jq -nc \
    --arg s 'posted gif to https://github.com/acme/foo/pull/42' \
    '{tool_name:"Bash",tool_input:{command:"tail -10 $CLAUDE_CONFIG_DIR/logs/pr-gif.log"},tool_response:{stdout:$s,output:""}}')
  run_script "$payload" >/dev/null
  local rc=$?
  local calls; calls=$(cat "$CALLS")
  teardown_mocks
  [ "$rc" -eq 0 ] && case "$calls" in *"op"*|*"curl"*|*"gh"*) return 1;; *) return 0;; esac
}

# Tag / rating customization

test_explicit_giphy_tag_env_overrides_inference() {
  setup_mocks
  PR_TITLE="chore: remove dead lambda" GIPHY_TAG="cats" \
    run_script "$(payload_with_stdout 'https://github.com/o/r/pull/10')" >/dev/null
  local tag; tag=$(extract_tag_from_calls)
  teardown_mocks
  [ "$tag" = "cats" ]
}

test_explicit_giphy_rating_env_overrides_default() {
  setup_mocks
  GIPHY_RATING="g" run_script "$(payload_with_stdout 'https://github.com/o/r/pull/11')" >/dev/null
  local rating; rating=$(extract_rating_from_calls)
  teardown_mocks
  [ "$rating" = "g" ]
}

test_default_rating_is_pg13() {
  setup_mocks
  run_script "$(payload_with_stdout 'https://github.com/o/r/pull/12')" >/dev/null
  local rating; rating=$(extract_rating_from_calls)
  teardown_mocks
  [ "$rating" = "pg-13" ]
}

test_removal_title_picks_from_removal_pool() {
  setup_mocks
  PR_TITLE="chore: remove unused lambda" \
    run_script "$(payload_with_stdout 'https://github.com/o/r/pull/13')" >/dev/null
  local tag; tag=$(extract_tag_from_calls)
  teardown_mocks
  case "$tag" in
    explosion|destroy|demolish|explode|delete|shredder) return 0 ;;
    *) echo "    got tag='$tag' expected one of the removal pool"; return 1 ;;
  esac
}

test_feature_title_picks_from_feature_pool() {
  setup_mocks
  PR_TITLE="feat: add new endpoint" \
    run_script "$(payload_with_stdout 'https://github.com/o/r/pull/14')" >/dev/null
  local tag; tag=$(extract_tag_from_calls)
  teardown_mocks
  case "$tag" in
    celebration|fireworks|yes|thumbs+up|high+five) return 0 ;;
    *) echo "    got tag='$tag' expected one of the feature pool"; return 1 ;;
  esac
}

test_unmatched_title_falls_back_to_funny() {
  setup_mocks
  PR_TITLE="docs: clarify something nondescript" \
    run_script "$(payload_with_stdout 'https://github.com/o/r/pull/15')" >/dev/null
  local tag; tag=$(extract_tag_from_calls)
  teardown_mocks
  [ "$tag" = "funny" ]
}

test_multi_word_tag_is_url_encoded() {
  setup_mocks
  GIPHY_TAG="thumbs up" \
    run_script "$(payload_with_stdout 'https://github.com/o/r/pull/16')" >/dev/null
  local tag; tag=$(extract_tag_from_calls)
  teardown_mocks
  [ "$tag" = "thumbs+up" ]
}

run_test "no PR URL → skip silently"                  test_no_pr_url_skips_silently
run_test "PR URL → op + curl + gh chain runs"         test_pr_url_triggers_full_chain
run_test "appended body preserves existing content"   test_appended_body_preserves_existing_content
run_test "op failure → skip gh"                       test_op_failure_short_circuits
run_test "empty Giphy response → skip gh"             test_giphy_empty_response_skips_post
run_test "curl failure → skip gh"                     test_curl_failure_skips_post
run_test "gh failure is non-fatal"                    test_gh_failure_is_swallowed
run_test "picks first PR URL when multiple"           test_picks_first_url_when_multiple
run_test "issue URLs are not treated as PRs"          test_ignores_non_pr_github_urls
run_test "non-gh-pr-create command with URL ignored"  test_non_pr_create_command_with_url_is_ignored
run_test "explicit GIPHY_TAG env overrides inference" test_explicit_giphy_tag_env_overrides_inference
run_test "explicit GIPHY_RATING env overrides default" test_explicit_giphy_rating_env_overrides_default
run_test "default rating is pg-13"                    test_default_rating_is_pg13
run_test "removal-themed title → removal pool tag"    test_removal_title_picks_from_removal_pool
run_test "feature-themed title → feature pool tag"    test_feature_title_picks_from_feature_pool
run_test "unmatched title → funny fallback"           test_unmatched_title_falls_back_to_funny
run_test "multi-word tag URL-encoded"                 test_multi_word_tag_is_url_encoded

print_summary

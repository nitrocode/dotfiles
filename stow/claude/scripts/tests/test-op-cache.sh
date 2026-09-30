#!/bin/bash
# Unit tests for $CLAUDE_CONFIG_DIR/scripts/op-cache.sh.
# Mocks `security` and `op` via PATH shims and a state file in a sandbox dir.
set -u
# shellcheck source=../../hooks/tests/_lib.sh
. "$CLAUDE_CONFIG_DIR/hooks/tests/_lib.sh"

REAL_HOME="$HOME"
SCRIPT="$CLAUDE_CONFIG_DIR/scripts/op-cache.sh"
echo "test-op-cache.sh:"

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  STATE="$SANDBOX/state"
  mkdir -p "$SANDBOX/bin" "$STATE"
  OP_CALLS="$STATE/op-calls.txt"
  RECOVER_CALLS="$STATE/recover-calls.txt"
  : >"$OP_CALLS"
  : >"$RECOVER_CALLS"

  # Mock `security` CLI. Stores entries as files at $STATE/<service>__<account>.
  # File format: line 1 = value, line 2 = creation timestamp (epoch).
  # `-w` is overloaded: it takes an argument for add (set password) and is a
  # boolean flag for find (output password only). Parse per subcommand.
  cat >"$SANDBOX/bin/security" <<'SEC'
#!/bin/bash
set -u
STATE="${SECURITY_MOCK_STATE:?need SECURITY_MOCK_STATE}"
cmd="$1"; shift

case "$cmd" in
  add-generic-password)
    svc=""; acct=""; pw=""; comment=""; update=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2;;
        -a) acct="$2"; shift 2;;
        -w) pw="$2"; shift 2;;
        -j) comment="$2"; shift 2;;
        -U) update=1; shift;;
        *) shift;;
      esac
    done
    file="$STATE/${svc}__${acct}"
    if [ -f "$file" ] && [ "$update" -eq 0 ]; then
      echo "security: duplicate item" >&2; exit 45
    fi
    printf '%s\n%s\n' "$pw" "$comment" >"$file"
    ;;
  find-generic-password)
    svc=""; acct=""; want_g=0; want_w=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2;;
        -a) acct="$2"; shift 2;;
        -w) want_w=1; shift;;
        -g) want_g=1; shift;;
        *) shift;;
      esac
    done
    file="$STATE/${svc}__${acct}"
    if [ ! -f "$file" ]; then
      echo "security: item not found" >&2; exit 44
    fi
    val=$(sed -n '1p' "$file")
    ts=$(sed -n '2p' "$file")
    if [ "$want_w" -eq 1 ]; then
      printf '%s' "$val"
    elif [ "$want_g" -eq 1 ]; then
      echo "keychain: \"$HOME/Library/Keychains/login.keychain-db\""
      echo "class: \"genp\""
      echo "attributes:"
      echo "    \"acct\"<blob>=\"$acct\""
      echo "    \"icmt\"<blob>=\"$ts\""
      echo "    \"svce\"<blob>=\"$svc\""
      printf 'password: "%s"\n' "$val"
    fi
    ;;
  delete-generic-password)
    svc=""; acct=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2;;
        -a) acct="$2"; shift 2;;
        *) shift;;
      esac
    done
    file="$STATE/${svc}__${acct}"
    [ -f "$file" ] && rm -f "$file"
    ;;
  dump-keychain)
    for f in "$STATE"/*__*; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      svc_part="${base%__*}"
      echo "    \"svce\"<blob>=\"$svc_part\""
    done
    ;;
  *) echo "mock security: unknown cmd $cmd" >&2; exit 99;;
esac
SEC
  chmod +x "$SANDBOX/bin/security"

  # Mock `op` CLI. `op read <ref>` echoes a deterministic token derived from the ref.
  cat >"$SANDBOX/bin/op" <<'OP'
#!/bin/bash
set -u
CALLS="${OP_MOCK_CALLS:?need OP_MOCK_CALLS}"
echo "$*" >> "$CALLS"
if [ "$1" = "read" ] && [ -n "${2:-}" ]; then
  case "$2" in
    op://empty/*) printf '' ;;
    op://fail/*) echo "op: fetch failed" >&2; exit 1 ;;
    op://flaky/*)
      # Fails until recovery has run (mock recovery touches $STATE/op-fixed).
      if [ -f "${SECURITY_MOCK_STATE:?}/op-fixed" ]; then
        printf 'token-after-recovery'
      else
        echo "op: delegated session failure" >&2; exit 1
      fi
      ;;
    *) printf 'token-for-%s' "$(printf '%s' "$2" | tr '/:' '__')" ;;
  esac
else
  exit 2
fi
OP
  chmod +x "$SANDBOX/bin/op"

  # Mock op-recover.sh. Records invocations and "fixes" the flaky op case.
  cat >"$SANDBOX/bin/op-recover-mock" <<'REC'
#!/bin/bash
set -u
echo "recover invoked" >> "${RECOVER_MOCK_CALLS:?need RECOVER_MOCK_CALLS}"
touch "${SECURITY_MOCK_STATE:?}/op-fixed"
REC
  chmod +x "$SANDBOX/bin/op-recover-mock"

  ORIG_PATH="$PATH"
  export PATH="$SANDBOX/bin:$PATH"
  export SECURITY_MOCK_STATE="$STATE"
  export OP_MOCK_CALLS="$OP_CALLS"
  export RECOVER_MOCK_CALLS="$RECOVER_CALLS"
  export OP_CACHE_BIN_SECURITY="$SANDBOX/bin/security"
  export OP_CACHE_BIN_OP="$SANDBOX/bin/op"
  export OP_CACHE_BIN_RECOVER="$SANDBOX/bin/op-recover-mock"
  export OP_CACHE_PREFIX="test-cache"
  export OP_CACHE_TTL=3600
  # Keep the interactive fallback off by default so tests never hang on a
  # prompt when the suite is run from a real terminal. Prompt-path tests
  # override per invocation.
  export OP_CACHE_NO_PROMPT=1
  # Pin USER so service keys are stable in tests.
  export USER="testuser"
}

teardown_sandbox() {
  export PATH="$ORIG_PATH"
  unset SECURITY_MOCK_STATE OP_MOCK_CALLS RECOVER_MOCK_CALLS OP_CACHE_BIN_SECURITY OP_CACHE_BIN_OP OP_CACHE_BIN_RECOVER OP_CACHE_PREFIX OP_CACHE_TTL OP_CACHE_NO_PROMPT
  rm -rf "$SANDBOX"
}

count_op_calls() { wc -l <"$OP_CALLS" | tr -d ' '; }

run_cache() { bash "$SCRIPT" "$@"; }

# --- tests ---

test_get_cache_miss_fetches_via_op_and_returns_value() {
  setup_sandbox
  local out; out=$(run_cache get my-token "op://Vault/Item/password" 2>/dev/null)
  local calls; calls=$(count_op_calls)
  teardown_sandbox
  [ "$out" = "token-for-op___Vault_Item_password" ] || { echo "got: $out"; return 1; }
  [ "$calls" = "1" ] || { echo "expected 1 op call, got $calls"; return 1; }
}

test_get_cache_hit_skips_op_call() {
  setup_sandbox
  run_cache get my-token "op://Vault/Item/password" >/dev/null 2>&1
  local calls_after_first; calls_after_first=$(count_op_calls)
  local out; out=$(run_cache get my-token "op://Vault/Item/password" 2>/dev/null)
  local calls_after_second; calls_after_second=$(count_op_calls)
  teardown_sandbox
  [ "$calls_after_first" = "1" ] || { echo "first call count $calls_after_first"; return 1; }
  [ "$calls_after_second" = "1" ] || { echo "expected no extra op call, got $calls_after_second"; return 1; }
  [ -n "$out" ] || return 1
}

test_get_expired_entry_refreshes_via_op() {
  setup_sandbox
  run_cache get my-token "op://Vault/Item/password" >/dev/null 2>&1
  # Backdate the entry's stored timestamp by 2 hours.
  local svc file old_ts
  svc="test-cache-my-token"
  file="$SECURITY_MOCK_STATE/${svc}__${USER}"
  old_ts=$(( $(date +%s) - 7200 ))
  printf '%s\n%s\n' "$(sed -n '1p' "$file")" "$old_ts" >"$file"
  run_cache get my-token "op://Vault/Item/password" >/dev/null 2>&1
  local total_calls; total_calls=$(count_op_calls)
  teardown_sandbox
  [ "$total_calls" = "2" ] || { echo "expected 2 op calls (initial + refresh), got $total_calls"; return 1; }
}

test_get_cache_miss_without_op_ref_fails() {
  setup_sandbox
  local rc=0; run_cache get my-token >/dev/null 2>&1 || rc=$?
  teardown_sandbox
  [ "$rc" = "2" ] || { echo "expected exit 2, got $rc"; return 1; }
}

test_set_then_get_skips_op() {
  setup_sandbox
  run_cache set my-token "literal-value" >/dev/null 2>&1
  local out; out=$(run_cache get my-token "op://Vault/Item/password" 2>/dev/null)
  local calls; calls=$(count_op_calls)
  teardown_sandbox
  [ "$out" = "literal-value" ] || { echo "got: $out"; return 1; }
  [ "$calls" = "0" ] || { echo "set should not trigger op, got $calls calls"; return 1; }
}

test_clear_removes_entry() {
  setup_sandbox
  run_cache set my-token "v1" >/dev/null 2>&1
  run_cache clear my-token >/dev/null 2>&1
  local rc=0; run_cache get my-token >/dev/null 2>&1 || rc=$?
  teardown_sandbox
  [ "$rc" = "2" ] || { echo "expected miss after clear, got rc=$rc"; return 1; }
}

test_invalid_name_rejected() {
  setup_sandbox
  local rc=0; run_cache get "bad name with spaces" "op://x/y/z" >/dev/null 2>&1 || rc=$?
  teardown_sandbox
  [ "$rc" = "4" ] || { echo "expected exit 4 for bad name, got $rc"; return 1; }
}

test_op_returns_empty_errors_out() {
  setup_sandbox
  local rc=0; run_cache get tok "op://empty/x/y" >/dev/null 2>&1 || rc=$?
  teardown_sandbox
  [ "$rc" = "3" ] || { echo "expected exit 3 for empty op value, got $rc"; return 1; }
}

test_prune_removes_expired_only() {
  setup_sandbox
  run_cache set fresh-token "v1" >/dev/null 2>&1
  run_cache set stale-token "v2" >/dev/null 2>&1
  # Backdate stale-token by 2 hours.
  local file="$SECURITY_MOCK_STATE/test-cache-stale-token__${USER}"
  local old_ts; old_ts=$(( $(date +%s) - 7200 ))
  printf '%s\n%s\n' "v2" "$old_ts" >"$file"
  run_cache prune >/dev/null 2>&1
  local fresh_rc=0; run_cache get fresh-token >/dev/null 2>&1 || fresh_rc=$?
  local stale_rc=0; run_cache get stale-token >/dev/null 2>&1 || stale_rc=$?
  teardown_sandbox
  [ "$fresh_rc" = "0" ] || { echo "fresh should survive, got rc=$fresh_rc"; return 1; }
  [ "$stale_rc" = "2" ] || { echo "stale should be pruned, got rc=$stale_rc"; return 1; }
}

test_list_shows_cached_entries() {
  setup_sandbox
  run_cache set tok-a "a" >/dev/null 2>&1
  run_cache set tok-b "b" >/dev/null 2>&1
  local out; out=$(run_cache list 2>/dev/null)
  teardown_sandbox
  assert_contains "$out" "test-cache-tok-a" || return 1
  assert_contains "$out" "test-cache-tok-b"
}

test_op_fetch_failure_propagates() {
  setup_sandbox
  local rc=0; run_cache get tok "op://fail/x/y" >/dev/null 2>&1 || rc=$?
  teardown_sandbox
  [ "$rc" != "0" ] || { echo "expected non-zero exit on op failure"; return 1; }
}

count_recover_calls() { wc -l <"$RECOVER_CALLS" | tr -d ' '; }

test_op_failure_runs_recovery_and_retries() {
  setup_sandbox
  local out; out=$(run_cache get tok "op://flaky/x/y" 2>/dev/null)
  local op_calls recover_calls
  op_calls=$(count_op_calls)
  recover_calls=$(count_recover_calls)
  teardown_sandbox
  [ "$out" = "token-after-recovery" ] || { echo "got: $out"; return 1; }
  [ "$recover_calls" = "1" ] || { echo "expected 1 recovery call, got $recover_calls"; return 1; }
  [ "$op_calls" = "2" ] || { echo "expected 2 op calls (fail + retry), got $op_calls"; return 1; }
}

test_prompt_fallback_caches_entered_value() {
  setup_sandbox
  local out
  out=$(printf 'manual-secret\n' | OP_CACHE_NO_PROMPT=0 OP_CACHE_ASSUME_TTY=1 run_cache get tok "op://fail/x/y" 2>/dev/null)
  # Second get must hit the cache (no further op calls beyond the failed ones).
  local calls_before; calls_before=$(count_op_calls)
  local out2; out2=$(run_cache get tok "op://fail/x/y" 2>/dev/null)
  local calls_after; calls_after=$(count_op_calls)
  teardown_sandbox
  [ "$out" = "manual-secret" ] || { echo "prompt value not returned, got: $out"; return 1; }
  [ "$out2" = "manual-secret" ] || { echo "cached value not returned, got: $out2"; return 1; }
  [ "$calls_before" = "$calls_after" ] || { echo "second get should not call op"; return 1; }
}

test_op_failure_no_tty_exits_3_with_manual_hint() {
  setup_sandbox
  local rc=0 err
  err=$(run_cache get tok "op://fail/x/y" 2>&1 >/dev/null) || rc=$?
  teardown_sandbox
  [ "$rc" = "3" ] || { echo "expected exit 3, got $rc"; return 1; }
  assert_contains "$err" "add-generic-password" || { echo "missing manual-seed hint"; return 1; }
}

run_test "get: cache miss fetches via op" test_get_cache_miss_fetches_via_op_and_returns_value
run_test "get: cache hit skips op call" test_get_cache_hit_skips_op_call
run_test "get: expired entry refreshes via op" test_get_expired_entry_refreshes_via_op
run_test "get: miss without op-ref returns exit 2" test_get_cache_miss_without_op_ref_fails
run_test "set: stored value bypasses op on subsequent get" test_set_then_get_skips_op
run_test "clear: removes the cached entry" test_clear_removes_entry
run_test "name: invalid characters rejected" test_invalid_name_rejected
run_test "op: empty value treated as error" test_op_returns_empty_errors_out
run_test "prune: removes expired only" test_prune_removes_expired_only
run_test "list: shows all cached entries" test_list_shows_cached_entries
run_test "op: fetch failure propagates" test_op_fetch_failure_propagates
run_test "recovery: op failure triggers recover + retry" test_op_failure_runs_recovery_and_retries
run_test "prompt: fallback value returned and cached" test_prompt_fallback_caches_entered_value
run_test "no-tty: exit 3 with manual seeding hint" test_op_failure_no_tty_exits_3_with_manual_hint

print_summary

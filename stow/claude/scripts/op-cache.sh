#!/usr/bin/env bash
# Cache 1Password secrets in macOS Keychain with TTL.
#
# Avoids re-prompting Touch ID on every `op` call by caching fetched values
# in the user's login keychain. Each entry stores its creation epoch in the
# comment field; reads check the age and refresh on expiry.
#
# Usage:
#   op-cache get <name> [op-ref]   # cache hit returns value; miss fetches via op
#   op-cache set <name> <value>    # store a value (no op lookup)
#   op-cache clear <name>          # delete the cached entry
#   op-cache prune                 # remove all expired entries
#   op-cache list                  # list cached entry names with ages
#
# On `op read` failure, `get` runs op-recover.sh once and retries; if op still
# fails and a TTY is attached, it falls back to a hidden interactive prompt
# (paste the value from the 1Password app, which works offline) and caches it.
#
# Env:
#   OP_CACHE_TTL=<seconds>         # override TTL (default 3600 = 1 hour)
#   OP_CACHE_PREFIX=<string>       # override keychain service prefix
#   OP_CACHE_BIN_SECURITY=<path>   # override `security` binary path (for tests)
#   OP_CACHE_BIN_OP=<path>         # override `op` binary path (for tests)
#   OP_CACHE_BIN_RECOVER=<path>    # override op-recover.sh path (for tests)
#   OP_CACHE_NO_PROMPT=1           # disable the interactive fallback prompt
#   OP_CACHE_ASSUME_TTY=1          # force the TTY check true (for tests)
#
# Example:
#   token=$(op-cache get atlassian-token "op://Private/atlassian-token/credential")
#   curl -u "you@example.com:$token" https://example.atlassian.net/rest/api/3/myself

set -euo pipefail

CACHE_PREFIX="${OP_CACHE_PREFIX:-claude-cache}"
TTL_SECONDS="${OP_CACHE_TTL:-3600}"
ACCOUNT="${USER}"
SECURITY_BIN="${OP_CACHE_BIN_SECURITY:-security}"
OP_BIN="${OP_CACHE_BIN_OP:-op}"
RECOVER_BIN="${OP_CACHE_BIN_RECOVER:-$CLAUDE_CONFIG_DIR/scripts/op-recover.sh}"

usage() {
  cat >&2 <<'EOF'
op-cache: cache 1Password secrets in macOS Keychain with TTL.

  op-cache get <name> [op-ref]   # cache hit returns value; miss fetches via op
  op-cache set <name> <value>    # store an arbitrary value
  op-cache clear <name>          # delete the cached entry
  op-cache prune                 # remove all expired entries
  op-cache list                  # list cached entry names with ages

Env:
  OP_CACHE_TTL=<seconds>         (default 3600)
EOF
  exit "${1:-1}"
}

# Service name = "<prefix>-<name>". Validate name to prevent injection.
kc_service() {
  local name="$1"
  if [[ ! "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "op-cache: name must match [A-Za-z0-9_.-]+, got: $name" >&2
    exit 4
  fi
  printf '%s-%s' "$CACHE_PREFIX" "$name"
}

# Parse the creation timestamp from the Keychain entry's comment (icmt) field.
# Prints empty string if no entry or no timestamp.
kc_get_timestamp() {
  local svc="$1"
  "$SECURITY_BIN" find-generic-password -s "$svc" -a "$ACCOUNT" -g 2>&1 \
    | awk -F'"' '/"icmt"<blob>=/ { print $4; exit }'
}

# Echo cached value if fresh; return non-zero if missing or expired (and delete expired).
kc_get_value_if_fresh() {
  local svc="$1"
  local now ts age
  now=$(date +%s)
  ts=$(kc_get_timestamp "$svc")
  if [[ -z "$ts" ]]; then
    return 1
  fi
  age=$(( now - ts ))
  if (( age > TTL_SECONDS )); then
    "$SECURITY_BIN" delete-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1 || true
    return 1
  fi
  "$SECURITY_BIN" find-generic-password -s "$svc" -a "$ACCOUNT" -w 2>/dev/null
}

kc_set() {
  local svc="$1" value="$2"
  local ts
  ts=$(date +%s)
  "$SECURITY_BIN" add-generic-password -s "$svc" -a "$ACCOUNT" -w "$value" -j "$ts" -U
}

kc_delete() {
  local svc="$1"
  "$SECURITY_BIN" delete-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1 || true
}

# List service names under our prefix.
kc_list() {
  "$SECURITY_BIN" dump-keychain 2>/dev/null \
    | awk -v prefix="${CACHE_PREFIX}-" '
        /"svce"<blob>=/ {
          if (match($0, /"[^"]*"$/)) {
            svc = substr($0, RSTART + 1, RLENGTH - 2)
            if (index(svc, prefix) == 1) print svc
          }
        }
      ' | sort -u
}

# True when the interactive fallback prompt is allowed and a TTY is attached.
can_prompt() {
  [[ "${OP_CACHE_NO_PROMPT:-0}" = "1" ]] && return 1
  [[ "${OP_CACHE_ASSUME_TTY:-0}" = "1" ]] && return 0
  [[ -t 0 && -t 2 ]]
}

# Hidden-input prompt for a manually pasted value (1Password app works offline).
prompt_for_value() {
  local name="$1" value
  {
    echo "op-cache: op read failed and recovery did not help."
    echo "op-cache: paste the value for '$name' (input hidden, e.g. from the 1Password app):"
  } >&2
  IFS= read -rs value
  echo >&2
  printf '%s' "$value"
}

# Fetch a secret: op read, then one op-recover.sh + retry, then interactive
# prompt. All non-value output goes to stderr (callers capture stdout).
fetch_value() {
  local name="$1" op_ref="$2" value
  if value=$("$OP_BIN" read "$op_ref") && [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ -f "$RECOVER_BIN" ]]; then
    echo "op-cache: op read failed; running recovery ($RECOVER_BIN)" >&2
    bash "$RECOVER_BIN" >&2 || true
    if value=$("$OP_BIN" read "$op_ref") && [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  if can_prompt; then
    value=$(prompt_for_value "$name") || value=""
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "op-cache: empty value entered at prompt" >&2
    return 1
  fi
  cat >&2 <<EOF
op-cache: could not fetch '$name' via op, and no TTY for the interactive fallback.
To cache it manually, run this in your own terminal (hidden prompt at the end):
  security add-generic-password -s "$(kc_service "$name")" -a "\$USER" -j "\$(date +%s)" -U -w
or re-run this command in a terminal to get the interactive prompt:
  $0 get $name $op_ref
EOF
  return 1
}

cmd_get() {
  local name="$1" op_ref="${2:-}"
  local svc value
  svc=$(kc_service "$name")
  if value=$(kc_get_value_if_fresh "$svc") && [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  if [[ -z "$op_ref" ]]; then
    echo "op-cache: cache miss for '$name' and no op-ref provided" >&2
    exit 2
  fi
  if ! value=$(fetch_value "$name" "$op_ref") || [[ -z "$value" ]]; then
    echo "op-cache: no value obtained for '$name'" >&2
    exit 3
  fi
  kc_set "$svc" "$value"
  printf '%s' "$value"
}

cmd_prune() {
  local svc ts now age
  now=$(date +%s)
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    ts=$(kc_get_timestamp "$svc")
    [[ -z "$ts" ]] && continue
    age=$(( now - ts ))
    if (( age > TTL_SECONDS )); then
      "$SECURITY_BIN" delete-generic-password -s "$svc" -a "$ACCOUNT" >/dev/null 2>&1 || true
      echo "pruned: $svc (age ${age}s)"
    fi
  done < <(kc_list)
}

cmd_list() {
  local svc ts now age
  now=$(date +%s)
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    ts=$(kc_get_timestamp "$svc")
    if [[ -n "$ts" ]]; then
      age=$(( now - ts ))
      printf '%-50s  age=%ss  ttl=%ss\n' "$svc" "$age" "$TTL_SECONDS"
    else
      printf '%-50s  (no timestamp)\n' "$svc"
    fi
  done < <(kc_list)
}

case "${1:-}" in
  get)
    [[ $# -lt 2 || $# -gt 3 ]] && usage
    cmd_get "$2" "${3:-}"
    ;;
  set)
    [[ $# -ne 3 ]] && usage
    [[ -z "$3" ]] && { echo "op-cache: value is empty" >&2; exit 5; }
    kc_set "$(kc_service "$2")" "$3"
    ;;
  clear)
    [[ $# -ne 2 ]] && usage
    kc_delete "$(kc_service "$2")"
    ;;
  prune)
    [[ $# -ne 1 ]] && usage
    cmd_prune
    ;;
  list)
    [[ $# -ne 1 ]] && usage
    cmd_list
    ;;
  ""|-h|--help|help)
    usage 0
    ;;
  *)
    usage 1
    ;;
esac

#!/usr/bin/env bash
# op-recover.sh
#
# Recover 1Password CLI session when `op whoami` reports "account not signed in"
# despite the desktop app being up. Root cause: stale 0-byte regular file at
# ~/.config/op/op-daemon.sock that blocks the daemon from creating a real Unix
# socket. See ~/.claude/projects/-Users-user-test/memory/reference_op_cli_recovery.md
#
# Usage:
#   op-recover.sh            # try recovery; require Touch ID prompt
#   op-recover.sh --account other-shorthand   # override $OP_ACCOUNT (unset = op's default account)
#
# Exit codes:
#   0 = signed in (either after recovery or already)
#   1 = recovery attempted but signin still failed (usually means the
#       "Integrate with 1Password CLI" toggle is off in Settings → Developer)
#   2 = op CLI not installed
set -euo pipefail

ACCOUNT="${OP_ACCOUNT:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --account)
      shift
      ACCOUNT="${1:-}"
      ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# --account only when one is configured; otherwise let op pick its default.
# The ${arr[@]+...} form keeps bash 3.2 + set -u happy with an empty array.
ACCT_ARGS=()
[ -n "$ACCOUNT" ] && ACCT_ARGS=(--account "$ACCOUNT")
ACCOUNT_LABEL="${ACCOUNT:-default account}"

if ! command -v op >/dev/null 2>&1; then
  echo "ERROR: op CLI not installed (brew install --cask 1password-cli)" >&2
  exit 2
fi

# Fast path: already signed in
if op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"} >/dev/null 2>&1; then
  echo "already signed in to $ACCOUNT_LABEL"
  op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"}
  exit 0
fi

# Step zero: ensure the 1Password desktop app is running. The CLI depends
# on it; if the app is closed, no recovery path can work.
if ! pgrep -x "1Password" >/dev/null 2>&1; then
  echo "1Password desktop app not running; launching in background"
  open -ga "1Password" 2>/dev/null || true
  # Wait up to 5s for the app process to appear
  for _ in 1 2 3 4 5; do
    sleep 1
    pgrep -x "1Password" >/dev/null 2>&1 && break
  done
  # Give the CLI integration a moment to register before retrying
  sleep 2
  if op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"} >/dev/null 2>&1; then
    echo "signed in after launching app"
    op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"}
    exit 0
  fi
fi

SOCK="$HOME/.config/op/op-daemon.sock"

# Diagnose stale socket: regular file (not socket type)
if [ -e "$SOCK" ] && [ ! -S "$SOCK" ]; then
  echo "removing stale non-socket file at $SOCK"
  rm -f "$SOCK"
fi

# Attempt signin via desktop app integration
echo "attempting op signin ($ACCOUNT_LABEL, may require Touch ID)"
if eval "$(op signin ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"})" 2>/dev/null && op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"} >/dev/null 2>&1; then
  echo "signed in successfully"
  op whoami ${ACCT_ARGS[@]+"${ACCT_ARGS[@]}"}
  exit 0
fi

cat >&2 <<EOF
ERROR: op signin produced no session.

Most likely cause: "Integrate with 1Password CLI" is OFF in the desktop app.

Fix:
  1. Open 1Password desktop app
  2. Settings → Developer
  3. Enable "Integrate with 1Password CLI"
  4. Also confirm Settings → Security has Touch ID enabled
  5. Re-run this script

If still failing, see:
  ~/.claude/projects/-Users-user-test/memory/reference_op_cli_recovery.md
EOF
exit 1

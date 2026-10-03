#!/usr/bin/env bash
# Wrapper around `rclone config <subcommand> ...` that redacts sensitive
# fields (token, client_secret, access_token, refresh_token, password, and
# any other key containing those substrings) from stdout/stderr before they
# reach the caller. rclone's own `config create`/`config update`/`config
# reconnect` print the full resulting remote config, including live OAuth
# tokens and client secrets, to stdout on success.
#
# Usage: rclone-config-safe.sh <rclone config subcommand> [args...]
# Example: bash ~/.claude/scripts/rclone-config-safe.sh update gdrive \
#            client_id "$CLIENT_ID" client_secret "$CLIENT_SECRET"
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: rclone-config-safe.sh <rclone config subcommand> [args...]" >&2
  exit 2
fi

subcommand="$1"

out_file="$(mktemp)"
err_file="$(mktemp)"
cleanup() { rm -f "$out_file" "$err_file"; }
trap cleanup EXIT

status=0
rclone config "$@" >"$out_file" 2>"$err_file" || status=$?

redact() {
  # Any config line whose key contains token/secret/password/passwd gets its
  # whole value blanked. client_id, type, scope, team_drive etc. pass through.
  sed -E 's/^([A-Za-z0-9_]*(token|secret|password|passwd)[A-Za-z0-9_]*)[[:space:]]*=.*/\1 = [REDACTED]/' "$1"
}

if [ "$status" -eq 0 ]; then
  echo "rclone config $subcommand: succeeded (sensitive fields redacted below)"
else
  echo "rclone config $subcommand: FAILED (exit $status) (sensitive fields redacted below)" >&2
fi

redact "$out_file"
redact "$err_file" >&2

exit "$status"

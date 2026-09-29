#!/bin/bash
# visibility: public
# SessionStart hook: warn if SaaS CLIs are not signed in.
# Non-blocking. Surfaces issues so workflows that depend on these tools fail upfront, not mid-task.
# Delegates to ensure-saas-login.sh --check-only, the single source of truth
# for which services to check (gh, op, aws, acli jira/confluence, slackcli,
# ntn, cycode, coderabbit). Wrapped in `timeout 20` so a slow/hanging network
# call can't stall session startup. 20s, not the tighter 5s originally used
# for the old aws/gh-only checks, because 9 sequential real CLI calls
# (several hitting the network) measured ~13s end to end in practice.

set -uo pipefail

SAAS_LOGIN_SCRIPT="$CLAUDE_CONFIG_DIR/scripts/ensure-saas-login.sh"

if [ -f "$SAAS_LOGIN_SCRIPT" ]; then
  OUTPUT="$(timeout 20 bash "$SAAS_LOGIN_SCRIPT" --check-only 2>&1)"
  RC=$?
  if [ "$RC" -eq 124 ]; then
    echo "Pre-flight: SaaS auth check timed out after 20s, skipping" >&2
  elif [ "$RC" -ne 0 ]; then
    echo "Pre-flight: SaaS auth issue(s) detected. Run: bash $CLAUDE_CONFIG_DIR/scripts/ensure-saas-login.sh" >&2
    printf '%s\n' "$OUTPUT" | grep '^  - ' >&2
  fi
else
  echo "Pre-flight: ensure-saas-login.sh not found at $SAAS_LOGIN_SCRIPT, skipping SaaS auth check" >&2
fi

exit 0

#!/usr/bin/env bash
# visibility: public
# SessionStart hook: surface Cycode-related session-time issues:
#   1) Cycode CLI not authenticated (no credentials file or explicit false)
#   2) In a git repo: .pre-commit-config.yaml missing or not referencing Cycode
# All warnings to stderr; non-blocking. Server-side token expiry will surface
# via downstream cycode scan failures, not from this local-only check.

set -uo pipefail

# 1) Auth check (local-only, fast)
if command -v cycode >/dev/null 2>&1; then
  AUTH=$(timeout 3 cycode -o json status 2>/dev/null | jq -r '.is_authenticated' 2>/dev/null)
  if [ "$AUTH" = "false" ]; then
    echo "Cycode CLI is not authenticated. Run 'cycode auth' to refresh your browser session. Cycode hooks will silently no-op on scan attempts until this is resolved." >&2
  fi
fi

# 2) pre-commit-config check (only inside a git repo)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
CONFIG="$REPO/.pre-commit-config.yaml"

if [ ! -f "$CONFIG" ]; then
  echo "Suggestion: $REPO has no .pre-commit-config.yaml. Consider adding Cycode pre-commit scanning (see cycode scan pre-commit, https://github.com/cycodehq/cycode-cli)." >&2
  exit 0
fi

if ! grep -qE '(cycode|cycodehq)' "$CONFIG"; then
  echo "Suggestion: $CONFIG exists but does not reference Cycode. Consider adding the Cycode pre-commit hook." >&2
fi

exit 0

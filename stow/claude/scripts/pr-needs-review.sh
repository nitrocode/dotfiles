#!/usr/bin/env bash
# List open PRs in a repo that have no review yet and no requested reviewer.
#
# Usage:
#   pr-needs-review.sh <owner/repo>
#
# Output: one line per PR needing review: "#<number>  <title>  (<url>)"
# Exit 0 with "No open PRs need review." if genuinely none, only after
# confirming the list call itself succeeded and returned well-formed JSON.
set -euo pipefail

usage() { echo "Usage: $(basename "$0") <owner/repo>" >&2; exit 2; }

[[ $# -eq 1 ]] || usage
REPO="$1"
[[ "$REPO" == */* ]] || { echo "ERROR: repo must be in owner/repo form, got '$REPO'" >&2; exit 2; }

RAW=$(gh pr list --repo "$REPO" --state open --json number,title,url,reviews,reviewRequests --limit 100 2>&1) || {
  echo "ERROR: gh pr list failed:" >&2
  echo "$RAW" >&2
  exit 1
}

if ! printf '%s' "$RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: unexpected response shape (expected a JSON array). Raw response:" >&2
  echo "$RAW" | jq . >&2 2>/dev/null || echo "$RAW" >&2
  exit 1
fi

TOTAL=$(printf '%s' "$RAW" | jq -r 'length')
if [[ "$TOTAL" -eq 100 ]]; then
  echo "WARNING: hit the 100-item --limit, results may be truncated. Re-run with a higher --limit if this repo has 100+ open PRs." >&2
fi

NEEDS_REVIEW=$(printf '%s' "$RAW" | jq -r '
  .[]
  | select((.reviews | length) == 0 and (.reviewRequests | length) == 0)
  | "#\(.number)  \(.title)  (\(.url))"
')

if [[ -z "$NEEDS_REVIEW" ]]; then
  echo "No open PRs need review. ($TOTAL open PR(s) total, all reviewed or have a reviewer requested.)"
  exit 0
fi

printf '%s\n' "$NEEDS_REVIEW"

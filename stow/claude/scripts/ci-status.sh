#!/usr/bin/env bash
# Summarize CI check status for a PR.
#
# Usage:
#   ci-status.sh <owner/repo> <pr-number>
#
# Exit codes: 0 = all checks passed, 1 = at least one failed, 2 = bad args,
# 3 = still pending (no failures yet, but not all done), 4 = gh call failed
# or response malformed (fail loud, don't report success on empty data).
set -euo pipefail

usage() { echo "Usage: $(basename "$0") <owner/repo> <pr-number>" >&2; exit 2; }

[[ $# -eq 2 ]] || usage
REPO="$1"
PR="$2"
[[ "$REPO" == */* ]] || { echo "ERROR: repo must be in owner/repo form, got '$REPO'" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "ERROR: PR number must be numeric, got '$PR'" >&2; exit 2; }

RAW=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup 2>&1) || {
  echo "ERROR: gh pr view failed:" >&2
  echo "$RAW" >&2
  exit 4
}

if ! printf '%s' "$RAW" | jq -e 'has("statusCheckRollup")' >/dev/null 2>&1; then
  echo "ERROR: unexpected response shape (missing statusCheckRollup). Raw response:" >&2
  echo "$RAW" | jq . >&2 2>/dev/null || echo "$RAW" >&2
  exit 4
fi

COUNT=$(printf '%s' "$RAW" | jq -r '.statusCheckRollup | length')
if [[ "$COUNT" -eq 0 ]]; then
  echo "No CI checks reported for PR #$PR yet." >&2
  exit 3
fi

# Normalize each check to name + a single status token: PASS / FAIL / PENDING.
SUMMARY=$(printf '%s' "$RAW" | jq -r '
  .statusCheckRollup[]
  | .name as $n
  | (.conclusion // .state // "PENDING") as $raw
  | ($raw | ascii_upcase) as $u
  | if ($u == "SUCCESS" or $u == "SUCCESS" or $u == "COMPLETED_SUCCESS") then "PASS"
    elif ($u == "FAILURE" or $u == "ERROR" or $u == "CANCELLED" or $u == "TIMED_OUT") then "FAIL"
    else "PENDING"
    end as $status
  | "\($status)\t\($n)"
')

echo "$SUMMARY" | sort | awk -F'\t' '{printf "  %-8s %s\n", $1, $2}'

FAIL_COUNT=$(echo "$SUMMARY" | grep -c '^FAIL' || true)
PENDING_COUNT=$(echo "$SUMMARY" | grep -c '^PENDING' || true)

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "$FAIL_COUNT check(s) failed." >&2
  exit 1
elif [[ "$PENDING_COUNT" -gt 0 ]]; then
  echo "$PENDING_COUNT check(s) still pending." >&2
  exit 3
else
  echo "All checks passed."
  exit 0
fi

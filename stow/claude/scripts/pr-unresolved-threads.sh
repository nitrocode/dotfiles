#!/usr/bin/env bash
# List unresolved GitHub PR review threads via GraphQL.
#
# Fails loud (non-zero exit + stderr message) on a malformed/empty GraphQL
# response instead of silently reporting "no unresolved threads", a prior
# session hit exactly that false negative from a bad jq path.
#
# Usage:
#   pr-unresolved-threads.sh <owner/repo> <pr-number>
#
# Output: one line per unresolved thread: "<url>, <first comment body, truncated>"
# Exit 0 with "No unresolved threads." if genuinely zero (only after
# confirming the query itself returned a well-formed, non-empty result).
set -euo pipefail

usage() { echo "Usage: $(basename "$0") <owner/repo> <pr-number>" >&2; exit 2; }

[[ $# -eq 2 ]] || usage
REPO="$1"
PR="$2"
[[ "$REPO" == */* ]] || { echo "ERROR: repo must be in owner/repo form, got '$REPO'" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "ERROR: PR number must be numeric, got '$PR'" >&2; exit 2; }

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

QUERY='
query($owner: String!, $name: String!, $pr: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        totalCount
        nodes {
          isResolved
          comments(first: 1) {
            nodes { url body }
          }
        }
      }
    }
  }
}'

RAW=$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F pr="$PR" 2>&1) || {
  echo "ERROR: gh api graphql call failed:" >&2
  echo "$RAW" >&2
  exit 1
}

# Fail loud if the response doesn't have the shape we expect, rather than
# letting a bad jq path downstream silently return empty/zero.
THREADS_PATH='.data.repository.pullRequest.reviewThreads'
if ! printf '%s' "$RAW" | jq -e "${THREADS_PATH} | has(\"totalCount\")" >/dev/null 2>&1; then
  echo "ERROR: unexpected GraphQL response shape (missing ${THREADS_PATH}.totalCount). Raw response:" >&2
  echo "$RAW" | jq . >&2 2>/dev/null || echo "$RAW" >&2
  exit 1
fi

TOTAL=$(printf '%s' "$RAW" | jq -r "${THREADS_PATH}.totalCount")

UNRESOLVED=$(printf '%s' "$RAW" | jq -r "
  ${THREADS_PATH}.nodes[]
  | select(.isResolved == false)
  | .comments.nodes[0]
  | \"\(.url), \(.body | .[0:100] | gsub(\"\\n\"; \" \"))\"
")

if [[ -z "$UNRESOLVED" ]]; then
  if [[ "$TOTAL" -eq 0 ]]; then
    echo "No review threads at all on PR #$PR (totalCount=0)."
  else
    echo "No unresolved threads. ($TOTAL total thread(s), all resolved.)"
  fi
  exit 0
fi

printf '%s\n' "$UNRESOLVED"

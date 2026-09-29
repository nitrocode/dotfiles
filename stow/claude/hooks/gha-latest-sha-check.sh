#!/bin/bash
# visibility: public
# PostToolUse hook: enforce latest SHA pins on GitHub Actions `uses:` lines.
#
# Fires after Write|Edit on .github/workflows/*.yml(.yaml) and
# .github/actions/*/action.yml(.yaml). For each `uses: <org>/<repo>@<sha> # vN`
# line, looks up the latest release tag SHA via `gh api` (24h cache) and
# rewrites the line in-place if outdated. Prints a system reminder listing
# what changed.
#
# Auto-fix shape: replaces both the SHA and the `# vN` comment so they
# stay in lockstep. Does not touch entries that already point at latest,
# entries without a comment, non-SHA refs (branches, tags), or entries
# marked `# vN pin-lock` (intentionally held back from auto-bump).
#
# Safe to run repeatedly. Network-quiet (cached) on warm runs.

set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty' 2>/dev/null)

if [[ -z "$FILE" || "$FILE" == "null" || ! -f "$FILE" ]]; then
  exit 0
fi

# Only act on GitHub Actions workflow/action files.
case "$FILE" in
  *.github/workflows/*.yml|*.github/workflows/*.yaml) ;;
  *.github/actions/*/action.yml|*.github/actions/*/action.yaml) ;;
  *) exit 0 ;;
esac

# Require gh on PATH; bail quietly if unavailable.
command -v gh >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CACHE_DIR="$CLAUDE_CONFIG_DIR/hooks/cache/gha-versions"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
TTL=86400  # 24h

# Returns "<latest_tag>\t<latest_sha>" for a given org/repo, cached.
lookup_latest() {
  local repo="$1"
  local safe="${repo//\//__}"
  local cache_file="$CACHE_DIR/$safe.tsv"
  local now
  now=$(date +%s)

  if [[ -f "$cache_file" ]]; then
    local mtime=""
    # BSD stat (macOS) and GNU stat (Linux) take different format flags.
    # Try BSD form first, fall back to GNU, validate the result is numeric.
    mtime=$(stat -f %m "$cache_file" 2>/dev/null)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$(stat -c %Y "$cache_file" 2>/dev/null)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if (( now - mtime < TTL )); then
      cat "$cache_file"
      return 0
    fi
  fi

  local tag sha
  tag=$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null) || return 1
  [[ -z "$tag" ]] && return 1
  sha=$(gh api "repos/$repo/commits/$tag" --jq .sha 2>/dev/null) || return 1
  [[ -z "$sha" ]] && return 1

  printf '%s\t%s\n' "$tag" "$sha" > "$cache_file"
  printf '%s\t%s\n' "$tag" "$sha"
}

# Extract: uses: <org>/<repo>@<40hex>( # <tag>)?
# Match group 1 = repo (org/repo), group 2 = current sha, group 3 = current tag comment.
USES_RE='^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40})([[:space:]]*#[[:space:]]*v?[0-9][0-9.]*)?[[:space:]]*$'

# Lines ending in "# ... pin-lock" (after the version comment) are
# intentionally held back from auto-bump, e.g.
# `uses: actions/checkout@<sha> # v4 pin-lock`. Checked as a plain substring
# (not a second `=~` test) so it doesn't clobber $BASH_REMATCH from the
# USES_RE match under `set -u`.

CHANGES=()
TMP="$FILE.gha-autofix.$$"
trap 'rm -f "$TMP"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ $USES_RE ]]; then
    repo="${BASH_REMATCH[1]}"
    cur_sha="${BASH_REMATCH[2]}"
    cur_comment="${BASH_REMATCH[3]:-}"

    if [[ "$line" == *pin-lock* ]]; then
      printf '%s\n' "$line" >> "$TMP"
      continue
    fi

    if result=$(lookup_latest "$repo"); then
      latest_tag=$(printf '%s' "$result" | cut -f1)
      latest_sha=$(printf '%s' "$result" | cut -f2)

      if [[ "$cur_sha" != "$latest_sha" ]]; then
        indent="${line%%[!- ]*}"
        prefix="${line%uses:*}"
        new_line="${prefix}uses: ${repo}@${latest_sha} # ${latest_tag}"
        CHANGES+=("$repo: $cur_sha (${cur_comment# #}) -> $latest_sha ($latest_tag)")
        printf '%s\n' "$new_line" >> "$TMP"
        continue
      fi
    fi
  fi
  printf '%s\n' "$line" >> "$TMP"
done < "$FILE"

if (( ${#CHANGES[@]} > 0 )); then
  mv "$TMP" "$FILE"
  {
    printf '⚠️  Auto-bumped %d outdated GitHub Action pin(s) in %s to latest:\n' "${#CHANGES[@]}" "$FILE"
    for c in "${CHANGES[@]}"; do printf '  - %s\n' "$c"; done
    printf 'If any of these were intentionally pinned, revert via git and add a comment explaining why.\n'
  } >&2
fi

exit 0

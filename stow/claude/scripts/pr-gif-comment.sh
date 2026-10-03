#!/usr/bin/env bash
# Appends a random gif to the PR body after `gh pr create`.
# Reads hook JSON from stdin, extracts the PR URL, picks a Giphy tag
# (env override > auto-derived from PR title > "funny"), fetches a
# random gif, and edits the PR body to append it.
# Silent on failure (best-effort). Logs to ~/.claude/logs/pr-gif.log.
#
# Env overrides:
#   GIPHY_TAG     — explicit tag (skips title-based inference)
#   GIPHY_RATING  — content rating (default: pg-13)
set -euo pipefail

LOG=$CLAUDE_CONFIG_DIR/logs/pr-gif.log
mkdir -p $CLAUDE_CONFIG_DIR/logs
ts() { date -u +%FT%TZ; }

# Maps a lowercased PR title to a tag picked randomly from a pool.
# Returns empty string when no keyword matches.
pick_tag_from_title() {
  local lower="$1"
  local -a pool=()
  case "$lower" in
    *remove*|*delete*|*retire*|*cleanup*|*drop*|*prune*|*kill*)
      pool=(explosion destroy demolish explode delete shredder) ;;
    *add*|*feat*|*introduce*|*implement*|*launch*)
      pool=(celebration fireworks yes "thumbs up" "high five") ;;
    *fix*|*repair*|*resolve*|*bug*)
      pool=("fix it" repair tools bandaid) ;;
    *refactor*|*rename*|*reorganize*|*move*)
      pool=(shuffle reorganize moving) ;;
    *upgrade*|*bump*|*update*)
      pool=(upgrade "level up" "glow up") ;;
    *) return 0 ;;
  esac
  echo "${pool[RANDOM % ${#pool[@]}]}"
}

payload=$(cat)
cmd=$(echo "$payload" | jq -r '.tool_input.command // ""')
if [[ "$cmd" != *"gh pr create"* ]]; then
  exit 0
fi

stdout=$(echo "$payload" | jq -r '.tool_response.stdout // .tool_response.output // ""')
pr_url=$(echo "$stdout" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)

if [[ -z "$pr_url" ]]; then
  echo "[$(ts)] gh pr create fired but no URL in stdout; payload: $(echo "$payload" | head -c 800)" >>"$LOG"
  exit 0
fi

api_key=$(op read "op://Employee/GIPHY/api key rb-cli" 2>>"$LOG" || true)
if [[ -z "$api_key" ]]; then
  echo "[$(ts)] could not read Giphy key from 1Password (is op signed in?), skipping" >>"$LOG"
  exit 0
fi

pr_data=$(gh pr view "$pr_url" --json body,title 2>>"$LOG" || true)
existing_body=$(printf '%s' "$pr_data" | jq -r '.body // ""')
pr_title=$(printf '%s' "$pr_data" | jq -r '.title // ""')

rating="${GIPHY_RATING:-pg-13}"
if [[ -n "${GIPHY_TAG:-}" ]]; then
  tag="$GIPHY_TAG"
else
  derived=$(pick_tag_from_title "$(echo "$pr_title" | tr '[:upper:]' '[:lower:]')")
  tag="${derived:-funny}"
fi

# URL-encode the tag (spaces -> +)
tag_enc="${tag// /+}"

giphy_json=$(curl -fsSL --max-time 10 \
  "https://api.giphy.com/v1/gifs/random?api_key=${api_key}&tag=${tag_enc}&rating=${rating}" \
  2>>"$LOG" || true)
gif_url=$(printf '%s' "$giphy_json" | jq -r '.data.images.original.url // empty' 2>>"$LOG" || true)

if [[ -z "$gif_url" ]]; then
  echo "[$(ts)] Giphy returned no gif for tag='$tag' rating='$rating', skipping" >>"$LOG"
  exit 0
fi

new_body="${existing_body}

![](${gif_url})"

if gh pr edit "$pr_url" --body "$new_body" >>"$LOG" 2>&1; then
  echo "[$(ts)] appended $gif_url (tag='$tag' rating='$rating') to body of $pr_url" >>"$LOG"
else
  echo "[$(ts)] gh pr edit failed for $pr_url" >>"$LOG"
fi

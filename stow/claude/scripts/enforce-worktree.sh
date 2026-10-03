#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write), blocks file edits when the target
# file's git repo is currently checked out on its base/default branch
# (main or master). Forces feature work into a git worktree on its own
# branch instead of editing the original clone directly.
#
# Reads the standard Claude Code PreToolUse JSON on stdin:
#   {"tool_name": "Edit", "tool_input": {"file_path": "/abs/path/to/file"}}
#
# Exit 0 + no output = allow. Prints a JSON "decision":"block" object to
# stdout to block the tool call with an explanatory reason.
set -euo pipefail

input=$(cat)

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

# No file path (e.g. NotebookEdit variants without file_path, or malformed
# input), nothing to check, allow.
if [ -z "$file_path" ]; then
  exit 0
fi

dir=$(dirname -- "$file_path")

# Not inside a git repo at all, nothing to enforce.
if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Personal repos under ~/git/personal are exempt: user has declared a
# standing global exception to edit main/master directly there, no
# worktree required. See feedback_personal_repos_main_branch_ok memory.
repo_root_check=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$repo_root_check" ]; then
  case "$repo_root_check" in
    "$HOME"/git/personal/*) exit 0 ;;
  esac
fi

branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)

# Detached HEAD or unborn branch, not "on the base branch" in the
# enforced sense, allow.
if [ -z "$branch" ]; then
  exit 0
fi

# Determine the repo's default/base branch: prefer origin/HEAD symbolic
# ref, fall back to checking for local main/master.
default_branch=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)

if [ -z "$default_branch" ]; then
  if git -C "$dir" show-ref --verify --quiet refs/heads/main; then
    default_branch="main"
  elif git -C "$dir" show-ref --verify --quiet refs/heads/master; then
    default_branch="master"
  fi
fi

# Still couldn't determine a default branch, nothing to compare against,
# allow rather than false-positive.
if [ -z "$default_branch" ]; then
  exit 0
fi

if [ "$branch" = "$default_branch" ]; then
  repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  reason="You're on the base branch ('"$branch"') in $repo_root. Create a worktree first, then edit there: git worktree add ../$(basename "$repo_root")-<feature> -b <feature-branch> origin/$default_branch"
  jq -n --arg reason "$reason" '{"decision":"block","reason":$reason}'
fi

exit 0

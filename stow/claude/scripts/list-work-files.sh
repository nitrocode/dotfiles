#!/usr/bin/env bash
# visibility: public
# list-work-files.sh - print all files marked `visibility: internal` (or missing marker).
# Quick "what's company-specific?" audit. Same scan dirs as sync-dotfiles.sh.

set -uo pipefail

SRC="${SRC:-$CLAUDE_CONFIG_DIR}"
SCAN_DIRS=("rules" "hooks" "scripts" "prompts" "agents" "commands" "git-hooks")
TOP_LEVEL_FILES=("RTK.md" "CLAUDE.md")

read_marker() {
  local f="$1"
  case "$f" in
    *.md)
      if head -1 "$f" 2>/dev/null | grep -qE '^---$'; then
        sed -n '/^---$/,/^---$/p' "$f" | grep -E '^visibility:' | head -1 | sed -E 's/visibility:[[:space:]]*//' | tr -d ' '
      else
        grep -m1 -oE '<!-- visibility: (public|internal) -->' "$f" 2>/dev/null | sed -E 's/<!-- visibility: ([a-z]+) -->/\1/'
      fi
      ;;
    *.sh|*.bash|*.zsh|*.py)
      grep -m1 -oE '^#[[:space:]]*visibility:[[:space:]]*(public|internal)' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]*visibility:[[:space:]]*//'
      ;;
    *.json)
      grep -m1 -oE '"_visibility"[[:space:]]*:[[:space:]]*"(public|internal)"' "$f" 2>/dev/null | sed -E 's/.*"(public|internal)".*/\1/'
      ;;
    *)
      grep -m1 -oE '^#[[:space:]]*visibility:[[:space:]]*(public|internal)' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]*visibility:[[:space:]]*//'
      ;;
  esac
}

INTERNAL=()
UNMARKED=()

for rel in "${TOP_LEVEL_FILES[@]}"; do
  full="$SRC/$rel"
  [ -f "$full" ] || continue
  marker=$(read_marker "$full")
  case "$marker" in
    internal) INTERNAL+=("$rel") ;;
    "")       UNMARKED+=("$rel") ;;
  esac
done

for dir in "${SCAN_DIRS[@]}"; do
  [ -d "$SRC/$dir" ] || continue
  while IFS= read -r -d '' full; do
    rel="${full#"$SRC/"}"
    marker=$(read_marker "$full")
    case "$marker" in
      internal) INTERNAL+=("$rel") ;;
      "")       UNMARKED+=("$rel") ;;
    esac
  done < <(find "$SRC/$dir" -type f -print0 2>/dev/null)
done

echo "=== INTERNAL (${#INTERNAL[@]}) ==="
printf '  %s\n' "${INTERNAL[@]}" | sort

echo ""
echo "=== UNMARKED (${#UNMARKED[@]}, defaults to internal) ==="
printf '  %s\n' "${UNMARKED[@]}" | sort

#!/usr/bin/env bash
# visibility: public
# regen-work-view.sh - rebuild ~/.claude/work/ as a symlink-only view of all internal files.
# Useful for browsing "all the company-specific stuff" in one tree.
# The symlinks are not loaded by Claude Code; loaders use the real paths.

set -uo pipefail

SRC="${SRC:-$CLAUDE_CONFIG_DIR}"
VIEW="${VIEW:-$SRC/work}"

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

is_internal() {
  local marker
  marker=$(read_marker "$1")
  [ "$marker" = "internal" ]
}

# Tear down old view (only if it exists and looks like our view)
if [ -d "$VIEW" ]; then
  # Safety: only remove if every entry is a symlink (our view) or empty
  if [ -z "$(find "$VIEW" -mindepth 1 -not -type l -not -type d -print -quit 2>/dev/null)" ]; then
    find "$VIEW" -type l -delete 2>/dev/null
    find "$VIEW" -type d -empty -delete 2>/dev/null
  else
    echo "warning: $VIEW contains non-symlink files; refusing to rebuild" >&2
    exit 1
  fi
fi

mkdir -p "$VIEW"

LINKED=0

link_file() {
  local rel="$1"
  local src_full="$SRC/$rel"
  local link_full="$VIEW/$rel"
  mkdir -p "$(dirname "$link_full")"
  ln -sf "$src_full" "$link_full"
  LINKED=$((LINKED + 1))
}

for rel in "${TOP_LEVEL_FILES[@]}"; do
  full="$SRC/$rel"
  [ -f "$full" ] || continue
  is_internal "$full" && link_file "$rel"
done

for dir in "${SCAN_DIRS[@]}"; do
  [ -d "$SRC/$dir" ] || continue
  while IFS= read -r -d '' full; do
    rel="${full#"$SRC/"}"
    is_internal "$full" && link_file "$rel"
  done < <(find "$SRC/$dir" -type f -not -path "*/work/*" -print0 2>/dev/null)
done

echo "Linked $LINKED internal files into $VIEW"
echo "(symlinks only - real files unchanged; loaders use original paths)"

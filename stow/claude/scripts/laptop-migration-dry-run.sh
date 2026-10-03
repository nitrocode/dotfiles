#!/usr/bin/env bash
# Dry-run size report for a laptop migration archive.
# Reads a plain-text include list (one path per line, ~ expands to $HOME,
# blank lines and #-comments ignored) and reports per-path size plus a total,
# without creating any archive or touching any files.
#
# Usage:
#   laptop-migration-dry-run.sh [include-list-file] [exclude-list-file]
#   (default to ~/.claude/scripts/laptop-migration-include-list.txt and
#   ~/.claude/scripts/laptop-migration-exclude-list.txt respectively)
#
# Exclude-list entries that fall under an include-list path have their size
# subtracted from that path's reported size (and from the total), since the
# pack script leaves them out of the archive too.
#
# Exit status: 0 always, unless the include-list file itself is missing/unreadable.

set -euo pipefail

LIST_FILE="${1:-$CLAUDE_CONFIG_DIR/scripts/laptop-migration-include-list.txt}"
EXCLUDE_FILE="${2:-$CLAUDE_CONFIG_DIR/scripts/laptop-migration-exclude-list.txt}"

# Optional untracked <list>.local next to the include list holds
# machine/org-specific paths that don't belong in the public list.
LOCAL_LIST_FILE="${LAPTOP_MIGRATION_LOCAL_LIST_FILE:-${LIST_FILE%.txt}.local}"

# Print the include list, then the local list if present. The echo keeps a
# missing trailing newline from gluing the two files' lines together.
include_lines() {
  cat "$LIST_FILE"
  echo
  if [ -r "$LOCAL_LIST_FILE" ]; then cat "$LOCAL_LIST_FILE"; fi
}

if [ ! -r "$LIST_FILE" ]; then
  echo "error: include list not readable: $LIST_FILE" >&2
  exit 1
fi

expand_tilde() {
  # Expand a leading ~ or ~/ to $HOME without invoking a subshell/eval
  # (avoids word-splitting or glob expansion on the rest of the path).
  local path="$1"
  case "$path" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${path#"~/"}" ;;
    *)     printf '%s' "$path" ;;
  esac
}

kb_to_human() {
  awk -v kb="$1" 'BEGIN {
    units[0]="K"; units[1]="M"; units[2]="G"; units[3]="T"
    v = kb; i = 0
    while (v >= 1024 && i < 3) { v /= 1024; i++ }
    printf "%.2f%s", v, units[i]
  }'
}

# Build the resolved, existing exclude paths up front so each included
# path's size can be netted against any exclude entries nested inside it.
exclude_resolved=()
if [ -r "$EXCLUDE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    resolved="$(expand_tilde "$line")"
    [ -e "$resolved" ] && exclude_resolved+=("$resolved")
  done < "$EXCLUDE_FILE"
fi

total_kb=0
missing=()
found_count=0
excluded_report=()

printf '%-60s %10s\n' "PATH" "SIZE"
printf '%-60s %10s\n' "----" "----"

while IFS= read -r line || [ -n "$line" ]; do
  # strip comments and surrounding whitespace
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue

  resolved="$(expand_tilde "$line")"

  if [ ! -e "$resolved" ]; then
    missing+=("$line")
    continue
  fi

  # du -sk gives a portable KB total on both GNU and BSD du
  kb="$(du -sk "$resolved" 2>/dev/null | awk '{print $1}')"
  kb="${kb:-0}"

  # subtract any excluded subpaths nested under this included path
  excluded_kb=0
  for ex in "${exclude_resolved[@]+"${exclude_resolved[@]}"}"; do
    case "$ex" in
      "$resolved"/*)
        exkb="$(du -sk "$ex" 2>/dev/null | awk '{print $1}')"
        exkb="${exkb:-0}"
        excluded_kb=$((excluded_kb + exkb))
        excluded_report+=("$ex ($(kb_to_human "$exkb"))")
        ;;
    esac
  done

  net_kb=$((kb - excluded_kb))
  total_kb=$((total_kb + net_kb))
  found_count=$((found_count + 1))

  human="$(kb_to_human "$net_kb")"
  printf '%-60s %10s\n' "$line" "$human"
done < <(include_lines)

echo
if [ ${#missing[@]} -gt 0 ]; then
  echo "Not found (skipped):"
  for m in "${missing[@]}"; do
    echo "  - $m"
  done
  echo
fi

if [ ${#excluded_report[@]} -gt 0 ]; then
  echo "Excluded (regenerate/reinstall on new laptop, see $EXCLUDE_FILE):"
  for e in "${excluded_report[@]}"; do
    echo "  - $e"
  done
  echo
fi

total_human="$(kb_to_human "$total_kb")"

echo "Included paths: $found_count"
echo "Missing paths:  ${#missing[@]}"
echo "Estimated total size: ${total_human} (${total_kb} KB, net of exclusions above)"
echo
echo "This does not account for tar/gzip compression, which will reduce the final archive size."

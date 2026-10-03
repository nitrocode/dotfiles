#!/usr/bin/env bash
# Build a laptop-migration archive from laptop-migration-include-list.txt and
# drop it into a Google Drive Desktop synced folder (if found), so Drive
# handles the actual upload with no manual step.
#
# Regenerates fresh artifacts first (Brewfile, crontab backup, editor
# extension lists, macOS defaults export) so the archive reflects current
# state, not a stale snapshot from whenever the include list was written.
#
# Usage:
#   laptop-migration-pack.sh [dest-dir]
#   dest-dir defaults to the first ~/Library/CloudStorage/GoogleDrive-*/My Drive
#   found, else falls back to ~/laptop-migration-transfer (local only, you'd
#   need to upload it yourself).
#
# Include list: ~/.claude/scripts/laptop-migration-include-list.txt
#   plus optional laptop-migration-include-list.local (untracked)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_FILE="${LAPTOP_MIGRATION_LIST_FILE:-$CLAUDE_CONFIG_DIR/scripts/laptop-migration-include-list.txt}"
EXCLUDE_FILE="${LAPTOP_MIGRATION_EXCLUDE_FILE:-$CLAUDE_CONFIG_DIR/scripts/laptop-migration-exclude-list.txt}"

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
DEST_DIR="${1:-}"

if [ -z "$DEST_DIR" ]; then
  drive_root="$(find "$HOME/Library/CloudStorage" -maxdepth 1 -iname 'GoogleDrive-*' 2>/dev/null | head -1)"
  if [ -n "$drive_root" ] && [ -d "$drive_root/My Drive" ]; then
    DEST_DIR="$drive_root/My Drive/laptop-migration"
    echo "Using Google Drive Desktop synced folder: $DEST_DIR"
  else
    DEST_DIR="$HOME/laptop-migration-transfer"
    echo "No Google Drive Desktop folder found under ~/Library/CloudStorage."
    echo "Falling back to a local folder: $DEST_DIR"
    echo "You'll need to upload the archive there yourself (Drive web UI, Finder, etc)."
  fi
fi
mkdir -p "$DEST_DIR"

echo
echo "=== Refreshing artifacts before packing ==="

if command -v brew >/dev/null 2>&1; then
  brew bundle dump --force --file="$HOME/Brewfile"
  echo "Brewfile refreshed."
else
  echo "brew not found, skipping Brewfile refresh (existing ~/Brewfile, if any, will still be included)."
fi

if crontab -l > "$HOME/crontab.backup.txt" 2>/dev/null; then
  echo "crontab.backup.txt refreshed."
else
  echo "no crontab for this user, removing stale crontab.backup.txt if present."
  rm -f "$HOME/crontab.backup.txt"
fi

if command -v code >/dev/null 2>&1; then
  code --list-extensions > "$HOME/vscode-extensions.txt"
  echo "vscode-extensions.txt refreshed."
fi
if command -v cursor >/dev/null 2>&1; then
  cursor --list-extensions > "$HOME/cursor-extensions.txt"
  echo "cursor-extensions.txt refreshed."
fi

if [ -x "$SCRIPT_DIR/macos-defaults-export.sh" ]; then
  "$SCRIPT_DIR/macos-defaults-export.sh" "$HOME/macos-defaults-backup" >/dev/null
  echo "macos-defaults-backup refreshed."
fi

echo
echo "=== Building archive ==="

if [ ! -r "$LIST_FILE" ]; then
  echo "error: include list not readable: $LIST_FILE" >&2
  exit 1
fi

pathlist="$(mktemp)"
trap 'rm -f "$pathlist"' EXIT

missing=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$line" ] && continue

  case "$line" in
    "~")   resolved="$HOME" ;;
    "~/"*) resolved="$HOME/${line#"~/"}" ;;
    *)     resolved="$line" ;;
  esac

  if [ ! -e "$resolved" ]; then
    missing=$((missing + 1))
    continue
  fi

  # store paths relative to $HOME so extraction on the new machine is a
  # straight `tar -C "$HOME" -xzf` with no path rewriting
  case "$resolved" in
    "$HOME"/*) printf '%s\n' "${resolved#"$HOME"/}" >> "$pathlist" ;;
    *) echo "warning: skipping path outside \$HOME (unsupported): $resolved" >&2 ;;
  esac
done < <(include_lines)

if [ ! -s "$pathlist" ]; then
  echo "error: no existing paths found from include list, nothing to archive" >&2
  exit 1
fi

exclude_args=()
excluded_count=0
if [ -r "$EXCLUDE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    case "$line" in
      "~")   resolved="$HOME" ;;
      "~/"*) resolved="$HOME/${line#"~/"}" ;;
      *)     resolved="$line" ;;
    esac

    case "$resolved" in
      "$HOME"/*)
        rel="${resolved#"$HOME"/}"
        exclude_args+=(--exclude="$rel")
        [ -e "$resolved" ] && excluded_count=$((excluded_count + 1))
        ;;
      *) echo "warning: skipping exclude path outside \$HOME (unsupported): $resolved" >&2 ;;
    esac
  done < "$EXCLUDE_FILE"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
archive="$DEST_DIR/laptop-migration-$timestamp.tar.gz"

tar -czf "$archive" "${exclude_args[@]+"${exclude_args[@]}"}" -C "$HOME" -T "$pathlist"

shasum -a 256 "$archive" | awk '{print $1}' > "$archive.sha256"

human_size="$(du -sh "$archive" | awk '{print $1}')"

echo
echo "Archive:  $archive"
echo "Checksum: $archive.sha256"
echo "Size:     $human_size"
echo "Missing paths skipped: $missing (run laptop-migration-dry-run.sh for details)"
echo "Excluded paths (reproducible cache/build output, not archived): $excluded_count (see $EXCLUDE_FILE)"
echo

if [[ "$DEST_DIR" == *"CloudStorage"* ]]; then
  echo "Drive Desktop will sync this in the background. Check the Drive menu bar icon for upload progress before wiping the old laptop."
else
  echo "Upload $archive (and its .sha256 file) to Drive yourself, then delete both from Drive once the new laptop confirms the restore."
fi

echo
echo "⚠️  Reminder: ~/.ssh is included in this archive. Consider rotating keys on the new laptop instead of reusing the copied ones."
if include_lines 2>/dev/null | grep -qE '^\s*~/\.aws(/|$)'; then
  echo "⚠️  Reminder: ~/.aws is included in this archive (added by explicit request). If it holds long-lived IAM keys, consider rotating them after migration; SSO/Identity Center sessions still need fresh login on the new laptop regardless."
fi
echo "⚠️  Not included (re-authenticate fresh on the new laptop instead): ~/.config/gcloud tokens, ~/.config/op, gh/git tokens, ~/.mcp-auth."
if [ "$excluded_count" -gt 0 ]; then
  echo "ℹ️  Excluded as reproducible cache/build output ($excluded_count path(s), see $EXCLUDE_FILE): rebuild via npm install / plugin reload / pip install as needed."
fi

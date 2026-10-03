#!/usr/bin/env bash
# Restore a laptop-migration archive (built by laptop-migration-pack.sh) onto
# a new machine.
#
# Default (no flags): dry-run only. Verifies checksum and lists what WOULD be
# extracted, changes nothing.
#   --extract        Actually extract the archive into $HOME.
#   --apply-configs  Implies --extract, and also runs the follow-up steps that
#                     change system state (brew bundle install, crontab
#                     install, reloading the custom launch agent).
#
# Usage:
#   laptop-migration-unpack.sh [source-dir] [--extract] [--apply-configs]
#   source-dir defaults to the first ~/Library/CloudStorage/GoogleDrive-*/My
#   Drive/laptop-migration found, else ~/laptop-migration-transfer.
#   Picks the most recently modified laptop-migration-*.tar.gz in that dir.

set -euo pipefail

SOURCE_DIR=""
EXTRACT=0
APPLY_CONFIGS=0

for arg in "$@"; do
  case "$arg" in
    --extract) EXTRACT=1 ;;
    --apply-configs) APPLY_CONFIGS=1; EXTRACT=1 ;;
    *) SOURCE_DIR="$arg" ;;
  esac
done

if [ -z "$SOURCE_DIR" ]; then
  drive_root="$(find "$HOME/Library/CloudStorage" -maxdepth 1 -iname 'GoogleDrive-*' 2>/dev/null | head -1)"
  if [ -n "$drive_root" ] && [ -d "$drive_root/My Drive/laptop-migration" ]; then
    SOURCE_DIR="$drive_root/My Drive/laptop-migration"
  else
    SOURCE_DIR="$HOME/laptop-migration-transfer"
  fi
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "error: source dir not found: $SOURCE_DIR" >&2
  echo "Make sure Drive Desktop has finished syncing, or pass the folder explicitly." >&2
  exit 1
fi

archive="$(ls -t "$SOURCE_DIR"/laptop-migration-*.tar.gz 2>/dev/null | head -1)"

if [ -z "$archive" ]; then
  echo "error: no laptop-migration-*.tar.gz found in $SOURCE_DIR" >&2
  exit 1
fi

echo "Found archive: $archive"

if [ -f "$archive.sha256" ]; then
  expected="$(cat "$archive.sha256")"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    echo "error: checksum mismatch, archive may be truncated or corrupted" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
  echo "Checksum verified OK."
else
  echo "warning: no .sha256 sibling found, skipping integrity check." >&2
fi

file_count="$(tar -tzf "$archive" | wc -l | tr -d ' ')"
echo "Contains $file_count entries."

if [ "$EXTRACT" -eq 0 ]; then
  echo
  echo "[dry-run] Would extract into: $HOME"
  echo "[dry-run] First 20 entries:"
  tar -tzf "$archive" | head -20
  echo
  echo "Re-run with --extract to actually extract, or --apply-configs to also run the follow-up config steps."
  exit 0
fi

echo
echo "=== Extracting into $HOME ==="
tar -xzf "$archive" -C "$HOME"
echo "Extraction complete."

if [ "$APPLY_CONFIGS" -eq 1 ]; then
  echo
  echo "=== Applying configs ==="

  if [ -f "$HOME/Brewfile" ]; then
    if command -v brew >/dev/null 2>&1; then
      brew bundle install --file="$HOME/Brewfile"
      echo "brew bundle install complete."
    else
      echo "brew not installed on this machine yet, skipping Brewfile install."
      echo "Install Homebrew first (https://brew.sh), then run: brew bundle install --file=\"\$HOME/Brewfile\""
    fi
  fi

  if [ -f "$HOME/crontab.backup.txt" ]; then
    crontab "$HOME/crontab.backup.txt"
    echo "crontab restored."
  fi

  agent_plist="$HOME/Library/LaunchAgents/com.user.claude-mcp-redact.plist"
  if [ -f "$agent_plist" ]; then
    launchctl bootstrap "gui/$(id -u)" "$agent_plist" 2>/dev/null \
      || launchctl load "$agent_plist" 2>/dev/null \
      || echo "warning: could not load $agent_plist, may already be loaded or need manual launchctl bootstrap."
    echo "launch agent bootstrap attempted."
  fi
fi

echo
echo "=== Manual follow-ups (not automated, need your judgment) ==="
echo "- macOS system settings: ~/.claude/scripts/macos-defaults-import.sh ~/macos-defaults-backup --apply"
echo "- Editor extensions: cat ~/vscode-extensions.txt | xargs -L1 code --install-extension  (and ~/cursor-extensions.txt if present)"
echo "- SSH keys: decide whether to reuse the copied ~/.ssh keys or rotate to a fresh keypair"
echo "- Re-authenticate: aws sso login, gcloud auth login, op signin, gh auth login, and any MCP server OAuth (~/.mcp-auth was not migrated)"
echo "- Once you've confirmed everything above works, delete the archive and .sha256 from Drive"

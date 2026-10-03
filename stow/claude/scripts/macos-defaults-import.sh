#!/usr/bin/env bash
# Companion to macos-defaults-export.sh. Run this on the NEW machine to
# reapply exported `defaults` domains from a macos-defaults-export.sh backup.
#
# This DOES mutate live settings on the machine it's run on. Prints a preview
# of what it will do; pass --apply to actually import (default is dry-run).
#
# Usage:
#   macos-defaults-import.sh [backup-dir] [--apply]
#   (backup-dir defaults to ~/macos-defaults-backup)

set -euo pipefail

BACKUP_DIR="$HOME/macos-defaults-backup"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    *) BACKUP_DIR="$arg" ;;
  esac
done

if [ ! -d "$BACKUP_DIR" ]; then
  echo "error: backup dir not found: $BACKUP_DIR" >&2
  exit 1
fi

# filename -> domain (inverse of the export script's mapping)
declare -A FILE_TO_DOMAIN=(
  ["dock.plist"]="com.apple.dock"
  ["finder.plist"]="com.apple.finder"
  ["keyboard-shortcuts.plist"]="com.apple.symbolichotkeys"
  ["global.plist"]="NSGlobalDomain"
  ["screencapture.plist"]="com.apple.screencapture"
  ["trackpad.plist"]="com.apple.AppleMultitouchTrackpad"
  ["input-sources.plist"]="com.apple.HIToolbox"
  ["spaces.plist"]="com.apple.spaces"
  ["system-preferences.plist"]="com.apple.systempreferences"
)

imported=0
missing=0

for outfile in "${!FILE_TO_DOMAIN[@]}"; do
  domain="${FILE_TO_DOMAIN[$outfile]}"
  src="$BACKUP_DIR/$outfile"

  if [ ! -f "$src" ]; then
    echo "missing: $outfile (no such file in $BACKUP_DIR, skipping $domain)"
    missing=$((missing + 1))
    continue
  fi

  if [ "$APPLY" -eq 1 ]; then
    defaults import "$domain" "$src"
    echo "imported $domain <- $src"
  else
    echo "[dry-run] would import $domain <- $src"
  fi
  imported=$((imported + 1))
done

echo
echo "Domains found: $imported"
echo "Domains missing from backup: $missing"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "Dry-run only, nothing was changed. Re-run with --apply to actually import."
else
  echo
  echo "Restart affected apps for changes to take effect, e.g.: killall Dock; killall Finder"
  echo "Note: MDM configuration profiles on this machine may override some of these regardless."
fi

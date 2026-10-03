#!/usr/bin/env bash
# Export a curated set of macOS `defaults` domains (Dock, Finder, keyboard
# shortcuts, trackpad, screenshots, etc.) to portable plist files, for
# reapplying on a new Mac via macos-defaults-import.sh.
#
# This does NOT touch any live system setting. It only reads current values
# via `defaults export` into $OUT_DIR.
#
# Usage:
#   macos-defaults-export.sh [output-dir]
#   (defaults to ~/macos-defaults-backup)

set -euo pipefail

OUT_DIR="${1:-$HOME/macos-defaults-backup}"

# domain -> output filename (kept explicit rather than looping all domains;
# exporting every domain on the machine pulls in app licensing/telemetry
# noise we don't want in a migration backup)
DOMAINS=(
  "com.apple.dock:dock.plist"
  "com.apple.finder:finder.plist"
  "com.apple.symbolichotkeys:keyboard-shortcuts.plist"
  "NSGlobalDomain:global.plist"
  "com.apple.screencapture:screencapture.plist"
  "com.apple.AppleMultitouchTrackpad:trackpad.plist"
  "com.apple.HIToolbox:input-sources.plist"
  "com.apple.spaces:spaces.plist"
  "com.apple.systempreferences:system-preferences.plist"
)

mkdir -p "$OUT_DIR"

exported=0
skipped=0

for entry in "${DOMAINS[@]}"; do
  domain="${entry%%:*}"
  outfile="${entry##*:}"
  target="$OUT_DIR/$outfile"

  if defaults export "$domain" "$target" 2>/dev/null; then
    echo "exported $domain -> $target"
    exported=$((exported + 1))
  else
    echo "skipped $domain (no such domain on this machine)"
    skipped=$((skipped + 1))
  fi
done

echo
echo "Exported: $exported domains to $OUT_DIR"
echo "Skipped:  $skipped domains (not present on this machine)"
echo
echo "To restore on the new machine, run macos-defaults-import.sh pointed at this directory."
echo "Some settings (e.g. Dock/Finder) need 'killall Dock' / 'killall Finder' after import to take effect."
echo "MDM configuration profiles on the new machine may override some of these regardless of import."

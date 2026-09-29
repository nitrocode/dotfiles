#!/usr/bin/env bash
# visibility: public
# PostToolUse hook: scan edited/written file for hardcoded secrets via Cycode CLI.
# Non-blocking warn so Claude sees output and can react.
# Skips binaries, lockfiles, generated artifacts.
#
# `cycode scan` is a network call (uploads the file to api.cycode.com and
# polls for the result), not a local static check -- observed latency is
# ~7-9.5s per call, occasionally hitting the 15s timeout below. That's
# inherent to the tool, not this script, so it stays synchronous (the whole
# point of this hook is Claude seeing the result before its next action).
# The one real lever available locally: skip re-scanning content that was
# already scanned clean recently, since Claude often edits the same file
# several times in a row. Findings are never cached/suppressed, only clean
# results, and only for a bounded TTL.

set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')

if [[ -z "$FILE" || "$FILE" == "null" || ! -f "$FILE" ]]; then
  exit 0
fi

# Skip non-scannable file types (binaries, lockfiles, generated, media)
case "$FILE" in
  *.lock|*.lockb|*lock.json|*lock.yaml|*lock.toml|*.log\
  |*.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.svg\
  |*.pdf|*.zip|*.tar|*.gz|*.tgz|*.bz2|*.xz|*.7z\
  |*.woff|*.woff2|*.ttf|*.eot\
  |*.mp3|*.mp4|*.mov|*.wav|*.mkv\
  |*.bin|*.exe|*.dll|*.so|*.dylib|*.class|*.o|*.a|*.pyc|*.pyo|*.wasm\
  |*.min.js|*.min.css)
    exit 0
    ;;
esac

if ! command -v cycode >/dev/null 2>&1; then
  exit 0
fi

# Cache dir overridable so tests can sandbox it; TTL overridable for tests.
CACHE_DIR="${CYCODE_SCAN_CACHE_DIR:-$CLAUDE_CONFIG_DIR/state/cycode-scan-cache}"
CACHE_TTL="${CYCODE_SCAN_CACHE_TTL:-3600}"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

CONTENT_HASH=$(shasum -a 256 "$FILE" 2>/dev/null | awk '{print $1}')
PATH_KEY=$(printf '%s' "$FILE" | shasum -a 256 | awk '{print $1}')
CACHE_FILE="$CACHE_DIR/$PATH_KEY"

if [[ -n "$CONTENT_HASH" && -f "$CACHE_FILE" ]]; then
  read -r cached_hash cached_at < "$CACHE_FILE" 2>/dev/null || true
  now=$(date +%s)
  if [[ "$cached_hash" == "$CONTENT_HASH" && -n "${cached_at:-}" && $((now - cached_at)) -lt "$CACHE_TTL" ]]; then
    exit 0
  fi
fi

# Single-file secret scan, short timeout
OUT=$(timeout 15 cycode --no-progress-meter --no-update-notifier scan --scan-type secret path "$FILE" 2>&1)
EXIT=$?

# cycode returns non-zero when findings exist; 124 = timeout
if [ "$EXIT" -ne 0 ] && [ "$EXIT" -ne 124 ]; then
  echo "WARNING: Cycode detected secret(s) in $FILE:" >&2
  echo "$OUT" | head -50 >&2
  # Do not cache: never suppress a repeat warning for content with findings.
else
  [[ -n "$CONTENT_HASH" ]] && printf '%s %s\n' "$CONTENT_HASH" "$(date +%s)" > "$CACHE_FILE" 2>/dev/null
fi

exit 0

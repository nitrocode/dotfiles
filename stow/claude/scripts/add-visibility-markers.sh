#!/usr/bin/env bash
# visibility: internal
# Backfill visibility markers across Claude config files.
# Internal because the FILES mapping contains paths that reveal company-specific filenames.
# To genericize: extract FILES mapping into a separate (internal) config file and have
# this script read it. Then mark this script public again.
# Idempotent: re-running updates only files whose marker differs.
#
# Marker locations by file type:
#   .md with YAML frontmatter -> `visibility:` key in frontmatter
#   .md without frontmatter   -> HTML comment near top
#   .sh / .bash / .zsh / .py  -> `# visibility: <vis>` after shebang
#   .json                     -> `"_visibility": "<vis>"` top-level key
#
# Usage:
#   bash add-visibility-markers.sh           # apply
#   bash add-visibility-markers.sh --check   # report missing/mismatched only

set -uo pipefail

CLAUDE="$CLAUDE_CONFIG_DIR"
MODE="${1:-apply}"

# Mapping: path (relative to $CLAUDE) -> visibility
declare -A FILES=(
  # PUBLIC: safe to upstream
  ["RTK.md"]="public"
  ["rules/editing-discipline.md"]="public"
  ["rules/drafts.md"]="public"
  ["rules/reusable-scripts.md"]="public"
  ["rules/task-tracking.md"]="public"
  ["rules/plan-mode.md"]="public"
  ["rules/subagent-scope.md"]="public"
  ["rules/review-feedback.md"]="public"
  ["rules/preflight-checks.md"]="public"
  ["rules/atmos-template-vars.md"]="public"
  ["hooks/em-dash-warn.sh"]="public"
  ["hooks/chmod-preserve.sh"]="public"
  ["hooks/lint-on-write.sh"]="public"
  ["hooks/format-yaml.sh"]="public"
  ["hooks/block-dangerous.sh"]="public"
  ["hooks/confirm-dialog.sh"]="public"
  ["hooks/rm-confirm.sh"]="public"
  ["hooks/preflight-check.sh"]="public"
  ["hooks/gh-pr-confirm.sh"]="public"
  ["hooks/notify-attention.sh"]="public"
  ["hooks/notify-done.sh"]="public"
  ["hooks/speak-summary.sh"]="public"
  ["hooks/otel-trace.py"]="public"
  ["git-hooks/prepare-commit-msg"]="public"
  ["git-hooks/README.md"]="public"
  ["scripts/aws-auth-refresh.sh"]="public"
  ["scripts/README.md"]="public"
  ["scripts/sync-dotfiles.sh"]="public"
  ["scripts/add-visibility-markers.sh"]="internal"
  ["scripts/run-hook-tests.sh"]="public"
  ["prompts/rubric.md"]="public"
  ["prompts/templates/directional-ask-v1.0.0.md"]="public"
  ["prompts/templates/extraction-skill-v1.0.0.md"]="public"
  ["prompts/templates/extraction-skill-v1.0.0.meta.json"]="public"
  ["agents/vibes-check.md"]="public"

  # INTERNAL: keep local, never upstream
  ["CLAUDE.md"]="internal"
  ["rules/jira-jql-conventions.md"]="internal"
  ["rules/commits.md"]="internal"
  ["rules/pull-requests.md"]="internal"
  ["rules/github-actions.md"]="internal"
  ["rules/bulk-operations.md"]="internal"
  ["rules/use-installed-tooling.md"]="internal"
  ["rules/pre-push-review.md"]="internal"
  ["commands/ag-prep.md"]="internal"
  ["commands/initiatives.md"]="internal"
  ["commands/jira-breakdown.md"]="internal"
  ["commands/lucid-style.md"]="internal"
  ["commands/morning.md"]="internal"
  ["scripts/rotate-byline.sh"]="internal"
  ["scripts/cr-rejected-comments.py"]="internal"
  ["scripts/trufflehog-scan.sh"]="internal"
  ["prompts/templates/review-fix-validate-v1.0.0.md"]="internal"
  ["prompts/templates/homebrew-tap-v1.0.0.md"]="internal"
  ["prompts/templates/homebrew-tap-v1.0.0.meta.json"]="internal"
)

# --- Read existing marker (returns "public", "internal", or "" if none) ---
read_marker() {
  local f="$1"
  case "$f" in
    *.md)
      # Check YAML frontmatter first
      if head -1 "$f" 2>/dev/null | grep -qE '^---$'; then
        sed -n '/^---$/,/^---$/p' "$f" | grep -E '^visibility:' | head -1 | sed -E 's/visibility:[[:space:]]*//' | tr -d ' '
      else
        # Check for HTML comment
        grep -m1 -oE '<!-- visibility: (public|internal) -->' "$f" 2>/dev/null | sed -E 's/<!-- visibility: ([a-z]+) -->/\1/'
      fi
      ;;
    *.sh|*.bash|*.zsh|*.py)
      grep -m1 -oE '^#[[:space:]]*visibility:[[:space:]]*(public|internal)' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]*visibility:[[:space:]]*//'
      ;;
    *.json)
      grep -m1 -oE '"_visibility"[[:space:]]*:[[:space:]]*"(public|internal)"' "$f" 2>/dev/null | sed -E 's/.*"(public|internal)".*/\1/'
      ;;
    prepare-commit-msg|*.txt)
      # No-extension shell scripts (git hooks)
      grep -m1 -oE '^#[[:space:]]*visibility:[[:space:]]*(public|internal)' "$f" 2>/dev/null | sed -E 's/^#[[:space:]]*visibility:[[:space:]]*//'
      ;;
  esac
}

# --- Insert/update marker in file ---
insert_marker() {
  local f="$1"
  local vis="$2"
  local tmp
  tmp=$(mktemp)

  case "$f" in
    *.md)
      if head -1 "$f" 2>/dev/null | grep -qE '^---$'; then
        # Has YAML frontmatter
        if grep -qE '^visibility:' "$f"; then
          # Replace existing visibility line
          sed -E "s/^visibility:.*/visibility: $vis/" "$f" > "$tmp"
        else
          # Insert visibility line just before closing ---
          awk -v vis="$vis" '
            BEGIN { in_fm=0; opened=0; inserted=0 }
            /^---$/ {
              if (!opened) { opened=1; print; next }
              if (!inserted) { print "visibility: " vis; inserted=1 }
            }
            { print }
          ' "$f" > "$tmp"
        fi
      else
        # No frontmatter; use HTML comment. Place AFTER line 1 if line 1 has
        # content (commands and slash skills use line 1 as the description).
        if grep -qE '<!-- visibility: (public|internal) -->' "$f"; then
          sed -E "s#<!-- visibility: (public|internal) -->#<!-- visibility: $vis -->#" "$f" > "$tmp"
        elif head -1 "$f" | grep -qE '^[A-Za-z#]'; then
          # Line 1 has content (heading or text): preserve it, marker on line 3.
          { head -1 "$f"; echo ""; echo "<!-- visibility: $vis -->"; tail -n +2 "$f"; } > "$tmp"
        else
          { echo "<!-- visibility: $vis -->"; echo ""; cat "$f"; } > "$tmp"
        fi
      fi
      ;;
    *.sh|*.bash|*.zsh|*.py)
      if head -1 "$f" | grep -qE '^#!'; then
        if grep -qE '^#[[:space:]]*visibility:' "$f"; then
          sed -E "s|^#[[:space:]]*visibility:.*|# visibility: $vis|" "$f" > "$tmp"
        else
          { head -1 "$f"; echo "# visibility: $vis"; tail -n +2 "$f"; } > "$tmp"
        fi
      else
        if grep -qE '^#[[:space:]]*visibility:' "$f"; then
          sed -E "s|^#[[:space:]]*visibility:.*|# visibility: $vis|" "$f" > "$tmp"
        else
          { echo "# visibility: $vis"; cat "$f"; } > "$tmp"
        fi
      fi
      ;;
    *.json)
      if grep -qE '"_visibility"' "$f"; then
        python3 -c "
import json, sys
p = '$f'
data = json.load(open(p))
if isinstance(data, dict):
    data['_visibility'] = '$vis'
    json.dump(data, open(p, 'w'), indent=2)
    open(p, 'a').write('\n')
" 2>/dev/null && cp "$f" "$tmp"
      else
        python3 -c "
import json
p = '$f'
data = json.load(open(p))
if isinstance(data, dict):
    new = {'_visibility': '$vis'}
    new.update(data)
    json.dump(new, open(p, 'w'), indent=2)
    open(p, 'a').write('\n')
" 2>/dev/null && cp "$f" "$tmp"
      fi
      ;;
    *)
      # No-extension scripts (e.g., git hooks)
      if head -1 "$f" | grep -qE '^#!'; then
        if grep -qE '^#[[:space:]]*visibility:' "$f"; then
          sed -E "s|^#[[:space:]]*visibility:.*|# visibility: $vis|" "$f" > "$tmp"
        else
          { head -1 "$f"; echo "# visibility: $vis"; tail -n +2 "$f"; } > "$tmp"
        fi
      fi
      ;;
  esac

  if [ -s "$tmp" ]; then
    cp -p "$tmp" "$f"
  fi
  rm -f "$tmp"
}

# --- Walk the mapping ---
NEW=0
UPDATED=0
UNCHANGED=0
MISSING_SRC=0

for rel in "${!FILES[@]}"; do
  vis="${FILES[$rel]}"
  full="$CLAUDE/$rel"

  if [ ! -f "$full" ]; then
    printf "  [MISSING-SRC]  %s\n" "$rel"
    MISSING_SRC=$((MISSING_SRC + 1))
    continue
  fi

  existing=$(read_marker "$full")

  if [ "$existing" = "$vis" ]; then
    printf "  [UNCHANGED]    %s  (already %s)\n" "$rel" "$vis"
    UNCHANGED=$((UNCHANGED + 1))
    continue
  fi

  if [ -z "$existing" ]; then
    printf "  [NEW-MARKER]   %s  -> %s\n" "$rel" "$vis"
    NEW=$((NEW + 1))
  else
    printf "  [UPDATE-MARKER] %s  %s -> %s\n" "$rel" "$existing" "$vis"
    UPDATED=$((UPDATED + 1))
  fi

  if [ "$MODE" != "--check" ]; then
    insert_marker "$full" "$vis"
  fi
done

echo ""
echo "Summary: $NEW new markers, $UPDATED updated, $UNCHANGED unchanged, $MISSING_SRC missing-source"
if [ "$MODE" = "--check" ]; then
  echo "Mode: --check (no files modified). Re-run without --check to apply."
fi

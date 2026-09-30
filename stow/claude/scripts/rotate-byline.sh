#!/usr/bin/env bash
# visibility: internal
# SessionEnd hook: rotate a display-only byline into ~/.claude/settings.json
# under the `.byline` key (subject / descriptor / emoji, same pools as
# before). This is flavor text only, NOT read by Claude Code as a commit/PR
# attribution instruction. Previously this wrote to `.attribution.commit`/
# `.attribution.pr`, which Claude Code injects as a system reminder telling
# the model to append it to every commit/PR; per explicit user feedback
# (2026-09-30, feedback_no_commit_attribution_lines memory) that behavior is
# unwanted. IMPORTANT: `.attribution.commit`/`.attribution.pr` must be set to
# empty strings, not deleted — deleting the key makes Claude Code fall back
# to its own hardcoded default attribution instead of suppressing it
# (confirmed live 2026-09-30). Empty string is what actually suppresses it.
# Edit SUBJECTS, TEMPLATES, EMOJIS, PR_FOOTERS below to customize.

set -uo pipefail

SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
[ -f "$SETTINGS" ] || exit 0

# Subject of the byline. %S% in templates is replaced with one of these.
SUBJECTS=(
  "Claude"
  "AI"
  "LLM"
  "my friend Claude"
  "the model"
  "the bot"
  "the assistant"
  "Claude.ai"
  "my CLI familiar"
  "AI pair"
  "RB's algorithmic pair"
)

# Generic templates that work with any subject (%S% + %E%).
TEMPLATES=(
  "Co-Authored-By: %S% (%E% the prompt-cached one) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% no em dashes since '26) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% verifies before editing) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% drafts not sends) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% caffeinated by context) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% your CLI familiar) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% token budget is real) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% RB's pair) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% trained on the public internet, mostly) <noreply@anthropic.com>"
  "Co-Authored-By: %S% (%E% context-aware sidekick) <noreply@anthropic.com>"
)

# Claude-specific templates (kept literal because they reference Anthropic specifics).
CLAUDE_TEMPLATES=(
  "Co-Authored-By: Claude 4.7 (%E% 1M context, 0 ego) <noreply@anthropic.com>"
  "Co-Authored-By: Claude (%E% running on opus[1m]) <noreply@anthropic.com>"
)

EMOJIS=(
  "🤖" "🧠" "⚡" "✨" "🎯" "🔧" "🚀" "📝" "💭" "🎨"
  "🦾" "☕" "🎲" "🔮" "🪄" "🦉" "🐙" "🦊" "🐢" "🦄"
  "🧪" "🛠" "📡" "🌀" "🎪" "🎭" "🗿" "🪐" "🌙" "☄"
)

PR_FOOTERS=(
  "%E% Co-authored with [Claude Code](https://claude.com/claude-code). Em-dash free."
  "%E% Built with [Claude Code](https://claude.com/claude-code) and 1-hour prompt cache."
  "%E% Pair-programmed with [Claude Code](https://claude.com/claude-code)."
  "%E% Drafted by [Claude Code](https://claude.com/claude-code), approved by a human."
  "%E% Generated with [Claude Code](https://claude.com/claude-code) on opus[1m]."
)

# Pool: ~80% generic templates (with subject variation), ~20% Claude-specific.
if [ $((RANDOM % 5)) -eq 0 ]; then
  TPL="${CLAUDE_TEMPLATES[$RANDOM % ${#CLAUDE_TEMPLATES[@]}]}"
  SUBJ=""
else
  TPL="${TEMPLATES[$RANDOM % ${#TEMPLATES[@]}]}"
  SUBJ="${SUBJECTS[$RANDOM % ${#SUBJECTS[@]}]}"
fi

PR_TPL="${PR_FOOTERS[$RANDOM % ${#PR_FOOTERS[@]}]}"
EMOJI_COMMIT="${EMOJIS[$RANDOM % ${#EMOJIS[@]}]}"
EMOJI_PR="${EMOJIS[$RANDOM % ${#EMOJIS[@]}]}"

PICK_COMMIT="${TPL//%S%/$SUBJ}"
PICK_COMMIT="${PICK_COMMIT//%E%/$EMOJI_COMMIT}"
PICK_PR="${PR_TPL//%E%/$EMOJI_PR}"

TMP="$SETTINGS.rotate.tmp"
if jq --arg c "$PICK_COMMIT" --arg p "$PICK_PR" \
      '.attribution.commit = "" | .attribution.pr = "" | .byline.commit = $c | .byline.pr = $p' \
      "$SETTINGS" > "$TMP" 2>/dev/null \
   && python3 -m json.tool "$TMP" >/dev/null 2>&1; then
  mv "$TMP" "$SETTINGS"
else
  rm -f "$TMP"
fi

exit 0

#!/bin/bash
# visibility: public
# UserPromptSubmit hook: detect prompts that read as open-ended asks (a goal
# named but no concrete approach/target) and nudge toward the brainstorming/
# plan-mode path from $CLAUDE_CONFIG_DIR/rules/plan-mode.md, instead of letting the
# ambiguity surface as scattered mid-task AskUserQuestion interrupts.
#
# Stdin: hook JSON with .user_prompt (or .prompt)
# Stdout: hookSpecificOutput with additionalContext if the prompt looks open-ended.
# Exit 0 either way. Soft nudge only, never blocks, never generates questions itself.
#
# Heuristic (deliberately cheap, no LLM call):
#   - prompt matches an open-ended phrase pattern (e.g. "how should we",
#     "figure out", "build a ... registry/system/pipeline", "set up some kind of")
#   - AND prompt has no concrete target already named (no file path / extension
#     token / backticked identifier)
#   - AND prompt is long enough to be a real ask, not a one-liner
#   - AND prompt isn't a pure informational question (those aren't implementation asks)

set -uo pipefail

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.user_prompt // .prompt // empty' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0
[ "${#PROMPT}" -lt 50 ] && exit 0

# Skip pure informational questions, they're not implementation asks.
if printf '%s' "$PROMPT" | grep -qiE '^(what is|what are|who is|who are|explain|define|when did|when was|why (is|does|did))'; then
  exit 0
fi

# Skip if a concrete target is already named (file path / extension token / backtick).
if printf '%s' "$PROMPT" | grep -qE '(/[a-zA-Z0-9_.-]+/|\.[a-zA-Z]{1,5}\b|`[^`]+`)'; then
  exit 0
fi

OPEN_ENDED='(figure out how|how should (we|i)|what.s the best way|should we (build|handle|do|design)|set up (a|some kind of)|build (a|some kind of) .*(registry|system|pipeline|framework)|come up with|design (a|an) .*(system|approach|architecture)|handle this|think through how|need (a|some) way to)'

if ! printf '%s' "$PROMPT" | grep -qiE "$OPEN_ENDED"; then
  exit 0
fi

BODY="This prompt reads as open-ended (goal named, no concrete approach/target yet). Per $CLAUDE_CONFIG_DIR/rules/plan-mode.md: consider superpowers:brainstorming or plan-mode, and batch every anticipated open question into one round-trip before implementing, rather than asking them one at a time mid-task."

jq -n --arg body "$BODY" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $body
  }
}'

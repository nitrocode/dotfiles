<!-- visibility: public -->

## Template Variables

| Placeholder | Description |
|---|---|
| `{{GOAL_SENTENCE}}` | One sentence: what you want done |
| `{{SUCCESS_CRITERIA}}` | 2-5 observable, checkable outcomes that mean "done" |
| `{{IN_SCOPE_FILES}}` | Files, dirs, or patterns to stay within |
| `{{OUT_OF_SCOPE_FILES}}` | Files, dirs, or patterns explicitly NOT to touch |
| `{{KNOWN_TRAPS}}` | Things that have gone wrong before in this area |
| `{{ANTI_GOALS}}` | Tempting-but-wrong moves to avoid |
| `{{TOKEN_BUDGET}}` | Approximate token cap for the work (e.g., "under 30k") |

---

# Directional Ask Scaffold

Use this when handing Claude a multi-step task that has gone wrong before due to wrong-approach iterations. Replaces the bare directional ask ("address all CodeRabbit feedback", "audit CODEOWNERS") with explicit success criteria up front.

**Why this exists:** Claude.ai Insights showed `wrong_approach` as the top friction (28 instances across 52 sessions), driven by directional asks lacking explicit success criteria. Filling this scaffold before sending reduces revert cycles.

---

## Goal

{{GOAL_SENTENCE}}

## Success criteria (define done)

The work is complete when **all** of these are observably true:

- [ ] {{SUCCESS_CRITERIA}}

## Scope

**In scope:**
- {{IN_SCOPE_FILES}}

**Out of scope (do NOT touch):**
- {{OUT_OF_SCOPE_FILES}}

## Known traps

{{KNOWN_TRAPS}}

## Anti-goals

Tempting moves that would be wrong here:

- {{ANTI_GOALS}}

## Working agreements

- **Verify before edit.** For diagnostic work, reproduce the failure and state the hypothesis before changing files. If uncertain, surface as `[UNVERIFIED]` and wait.
- **Minimal edit.** Smallest change that meets success criteria. No "while I'm here" cleanups unless I approve.
- **Token budget:** {{TOKEN_BUDGET}}. State estimated cost for any plan that exceeds 10k tokens before executing.
- **Drafts not sends.** Slack/Confluence/external comms produced as drafts. Wait for "send it".
- **Tests-first** for new behavior; existing tests must stay green.

## Output expectations

When you finish, report:

1. What was changed (files, key diffs)
2. Which success criteria are now met
3. Any criteria not met and why
4. Anything you noticed but did not act on (separate proposals)

---

**Drop the placeholders, paste this as your first message in a new session, and start there.**

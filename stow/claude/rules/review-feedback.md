---
description: Verify each review finding against actual code before fixing - reject false positives with reasoning
visibility: public
---

# Review Feedback Validation

<!-- [tackroom] adopted 2026-05-12 -->

When addressing CodeRabbit, Sonar, or human review comments, do NOT blindly apply fixes. Validate first.

## Process

For each finding:

1. **Quote** the comment.
2. **Read** the cited file/lines in the current code state.
3. **Judge** validity with evidence:
   - Is the finding factually true against current code?
   - Does it conflict with established conventions (style guide, repo CLAUDE.md, security rules)?
   - Has it already been addressed elsewhere?
4. **Output a verdict**: `VALID` (fix it), `INVALID` (dismiss with reason), or `NEEDS-USER` (call it out for human judgment).
5. **Wait for approval** on the verdict batch before applying any fixes.
6. **Apply** only the VALID fixes. Draft respectful dismissal replies for INVALID ones.

## Why this works

In one tracked session, 3 of 4 CodeRabbit findings were invalid. Blindly applying would have introduced regressions (e.g., the Sonar temp-file refactor based on a false premise that had to be fully reverted). Validation costs minutes, regressions cost hours.

## Anti-patterns

- "Auto-fix all CodeRabbit comments" without a verification pass.
- Treating any tool's suggestion as authoritative. Tools have false positive rates.
- Hiding the dismissal reasoning. If a finding is rejected, the reply must explain why so the reviewer does not re-flag.
- Resolving human-author threads. Leave those for the user.

## Skill / template

See `~/.claude/prompts/templates/review-fix-validate-v1.0.0.md` for a ready-to-paste workflow scaffold.

## Edge cases

- If a finding is technically valid but rejected for a non-obvious reason (e.g., intentional pattern, repo-specific override), document the reason in the dismissal reply AND surface it for me to consider adding to the repo's CLAUDE.md.
- If a finding uncovers a deeper issue beyond the surface fix, flag it separately. Do not silently expand scope.

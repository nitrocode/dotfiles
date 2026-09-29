---
description: Propose a plan before editing for changes touching 3+ files OR introducing new architecture
visibility: public
---

# Plan Before Editing

<!-- [tackroom] adopted 2026-05-12 -->

For any change that touches **3+ files** OR introduces **new architecture** (new module, new pattern, new abstraction) OR is **genuinely open-ended** even on a single file (the ask names a goal but not a concrete approach, e.g. "build a registry for X", "figure out how we should handle Y"), propose a plan **before** editing. Wait for approval.

## Batch open questions before writing the plan

Before drafting the plan itself, surface every open question you can anticipate in one round-trip (one `AskUserQuestion` call, or inline in the same message as the plan with a stated default per question), not one at a time as they occur to you mid-plan or mid-implementation. See `reduce-avoidable-asks.md`'s "Batch multi-part design questions" section, this rule is where that pattern actually gets applied.

Exception: if an early answer would reshape which questions are even worth asking, ask that one first rather than guessing at the rest speculatively.

## Large or genuinely new features: interview, spec, then fresh session

For a feature big enough that batched questions alone won't surface everything (new integration, new subsystem, anything where you'd expect a design doc), don't plan and implement in the same session that did the exploring.

1. Interview via `AskUserQuestion` until technical implementation, UI/UX, edge cases, and tradeoffs are covered, not just the obvious questions.
2. Write the result to `SPEC.md` (or `~/.claude/plans/<topic>.md` per the 10+ file case below): name the files/interfaces involved, state what's out of scope, end with an end-to-end verification step.
3. Start a **new session** to implement against the spec. The implementation session's context is then 100% relevant to the build, not cluttered with the back-and-forth that produced the spec.

**Why**: a session that interviews, plans, and implements in one thread accumulates irrelevant exploration context by the time coding starts, the same "kitchen sink session" pattern that makes `/clear` necessary mid-task. Starting implementation fresh against a written spec avoids needing to `/clear` and re-explain later.

## Always-plan files (single-file rule)

The 3+ file threshold is **waived** for these high-blast-radius live-config files. A plan is required even for a single-file edit:

- `renovate.json`, `renovate.json5`, `.renovaterc*` (cross-repo automation)
- `CODEOWNERS` (changes review routing org-wide)
- `.pre-commit-config.yaml` (auto-fix hooks can rewrite unrelated files)
- `.coderabbit.yaml`, `.coderabbit.yml` (cross-PR review behavior)
- `atlantis.yaml.custom`, `atmos.yaml` (CI plan/apply graph)
- `Renovate*.yaml` / Renovate auto-merge configs in `.github/`
- Any `repos.yaml` for Atlantis or org-level config

State the blast radius explicitly: which repos / CI jobs / reviewers are affected. Prefer a temp/test repo or a draft PR for risky changes; do not swap a live config in place without approval.

**Why**: Past sessions show wrong-approach friction on live configs (live `renovate.json5` swap, pre-commit auto-fix touching dozens of unrelated files). The cost of a 30-second plan is far less than the cleanup.

## What a plan contains

- **Goal**: one sentence
- **Files affected**: list with what changes in each
- **Approach**: 2-3 sentences, including tradeoffs
- **Verification**: how we know it worked (tests, linter, manual check)
- **Out of scope**: explicit anti-goals to prevent scope creep

## How to deliver it

- Inline in the response, scannable. Lead with the goal.
- For larger plans (10+ files, week-long work), use `superpowers:writing-plans` and save to `~/.claude/plans/<topic>.md`.
- Wait for approval before editing. If the user says "go", proceed.

## When to skip

- Single-file changes where the approach is already concrete and unambiguous (the open-ended exception above is for single-file asks that are genuinely underspecified, not every single-file edit)
- Trivial edits (rename, comment, typo)
- User says "just do it" or paste-the-code requests
- Read-only investigation (no edits coming)

## Why

Insights showed `wrong_approach` (31) as the top friction across 56 sessions. Multiple sessions had speculative edits later reverted. A short plan is the cheapest correction point.

A follow-up review (2026-08-02) of `AskUserQuestion` interrupts found the same root cause showing up as scattered mid-task asks instead of an upfront plan: an underspecified single-file ask ("how should the alph registry be set up") generated design questions one at a time across an entire session rather than a single batched plan at the start.

## Integration with existing skills

- `superpowers:brainstorming` — mandatory before non-trivial creative work
- `superpowers:writing-plans` — for plans persisted to specs
- `analytical-toolkit:rpiv-workflow` — research → plan → implement → verify
- `permissions.defaultMode: "plan"` — global plan mode (currently off; turn on per-session via `/permission plan` if desired)

This rule is the lightweight default for anything those skills don't already cover.

---
description: Use TaskCreate for any multi-step task (3+ steps); update as you go; mark completed immediately
visibility: public
---

# Task Tracking

<!-- [tackroom] adopted 2026-05-12 -->

When a task involves **3+ discrete steps**, create a task list via `TaskCreate` at the start. Update status as work progresses. Mark items completed immediately, do not batch at the end.

## When to use

- Multi-file changes (read, plan, implement, verify across 2+ files)
- Multi-step workflows (PR creation: review then fix then commit then push then create)
- Investigation + implementation (research, propose, implement, verify)
- Anything with explicit phases the user might want to track

## When to skip

- Single-step asks ("read this file", "what is X?")
- One-shot edits ("change `foo` to `bar` in file X")
- Trivial Q+A turns

## Rules

1. Create the full list **up front** when starting. Updating mid-flight is fine but always have a snapshot.
2. Set `in_progress` when starting a task. Set `completed` immediately when done. No batching.
3. One task at a time in `in_progress` (sequential).
4. If a task spawns subtasks, add them to the list (do not bury them in body).
5. Clean up stale lists when work moves on.

## Why

Insights showed `wrong_approach` (31 instances) as the top friction. Explicit task tracking reduces "where are we?" loss between turns and forces decomposition before action. The list is visible to the user, who can interrupt early if direction drifts.

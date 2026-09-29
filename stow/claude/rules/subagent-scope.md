---
description: Subagents (Task tool) for read-only exploration only - mutating ops happen in main thread
visibility: public
---

# Subagent Scope

<!-- [tackroom] adopted 2026-05-12 -->

When dispatching a Task subagent (Explore, general-purpose, etc.):

## Default scope: read-only exploration

- Grep, Read, Glob, find, grep-style discovery.
- Researching code patterns, finding files, summarizing distributed evidence.
- Pure-analysis questions where the agent returns findings, not changes.

## Mutating ops stay in main thread

- Bash with side effects (writes, commits, network calls)
- Edit, Write, NotebookEdit
- MCP tools that modify state (Jira transitions, Slack posts, file system writes)
- Any tool whose arguments the user might want to see before approval

## Why

Subagents hit Bash permission boundaries that the main thread does not, causing alignment ping-pong and silent fallbacks. Reading is safe to delegate. Writing is not.

## When to deviate

- Explicitly stateless writes (e.g., creating a clearly-throwaway file inside a sandboxed working dir) are fine.
- Multi-agent parallel write workflows (autonomous PR fleets, etc.) require explicit user approval per session. Do not initiate without it.
- If a subagent says "I cannot do X due to permissions", do NOT retry with broader scope. Return to the main thread and surface the limit.

## How to brief a read-only subagent

- Be explicit in the prompt: "research-only. Do not call Edit, Write, or any mutating Bash."
- Ask for findings, not actions. The agent reports; you act.
- Cap output length so the agent does not bury the answer in raw evidence.

## Require a results contract, reject bare pings

- When delegating (including parallel fan-out across repos/PRs), require each subagent to return concrete results in its final message: files changed, PR URLs, exact commands run, findings with file:line. A bare "done" or idle notification with no content is an invalid response.
- If a subagent goes idle without delivering that content, do not wait on it. Take over the work directly in the main thread and say explicitly which subagent's work you took over.
- Cap parallel subagent fan-out at 3-4 for review-style work (e.g. multi-PR review), and check in after each step rather than letting them run unattended to completion.

**Why**: During a 6-parallel-PR review, subagents repeatedly went idle without delivering results, compounded by stale worktrees, forcing the main thread to redo their work. Bare `idle_notification` pings with no status content forced re-verification from scratch. (Insights review, 2026-08-02.)

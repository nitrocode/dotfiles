---
description: Pre-flight checks for MCPs, authentication, and local tooling before starting workflows that depend on them
visibility: public
---

# Pre-Flight Checks

<!-- [tackroom] adopted 2026-05-09 -->

Before starting any workflow that depends on external resources, verify they are available. Failing late costs more than checking early.

## MCPs

- If a workflow needs an MCP (Slack, Atlassian, Nightfall, Google Workspace, GitHub, etc.), confirm the MCP is connected before any data gathering.
- If an MCP call fails with auth or connectivity errors, **stop**. Tell me which MCP is unavailable and how to reconnect. Do not substitute curl, scraping, or another MCP.
- For multi-phase workflows (`/morning`, `/initiatives`, security audits), batch-check all required MCPs first and report missing ones in one message before doing any work.

## Authentication

- **1Password**: confirm `op whoami` is signed in before any `op run` or `op item` calls.
- **AWS SSO**: confirm `aws sts get-caller-identity` works (or the relevant profile is active) before AWS API work.
- **gh CLI**: confirm `gh auth status` shows logged in to the right host before PR or issue work.
- **kubectl**: confirm context is set to the expected cluster before any cluster operation.
- If any auth check fails, surface the exact remediation command and pause. Do not keep going with degraded auth.

## Local tooling

- For workflows that depend on a local binary (icalBuddy, atmos at a pinned version, opa, conftest, terraform, jq, yq), check it is installed and on PATH before invoking.
- If missing, print the install command (brew, asdf, apt, etc.) and stop the dependent step. Do not fail the whole workflow over one missing tool. Report and continue with what you can.

## Settings integrity

- Before relying on hooks or the permission allowlist being active (start of session, or after `/doctor`, a skill install, or anything else that touches config), spot check `~/.claude/settings.json`: `wc -c` for non-zero, `jq -e . ~/.claude/settings.json` for valid JSON.
- If it's 0 bytes or invalid, **stop**. Don't proceed as if hooks/permissions are active. Check for a recent `~/.claude/settings.json.bak*` sibling before doing anything else, and surface the gap (how long it's likely been broken, based on file mtime) before restoring.
- This file fails silently, no startup error, no warning. See `feedback_settings_json_integrity` memory for the 2026-08-05 incident (empty since Aug 3, restored from `.bak-skillhook`; 4 historical `.bak*` variants found, suggesting this has happened before).

## Sandbox blockers

Claude Code's sandbox blocks several common operations. Anticipate these instead of failing into them.

Commonly blocked:

- `chmod`, `mkdir` against paths outside the working tree
- Writes to `~/.claude/` (settings, hooks, scripts)
- GPG signing for git commits (`gpg --sign`, `git commit -S`)
- `sudo` and privileged commands
- Outbound network from short-lived helper scripts (`gh api`, `curl`, `go build` fetching modules)
- `terraform destroy` / `terraform apply` when they need network egress

Rules:

- Before running any of these, name the constraint: "this needs sandbox off; want me to ask, or flip it first?"
- Do not retry the same blocked command in a loop. The sandbox state has not changed.
- For one-off scripts, prefer `~/.claude/scripts/` (an allowed write target) over `/tmp/` if the script needs to persist across a sandbox flip.

## Auto-mode classifier outages

`auto` permission mode depends on a classifier model being reachable. When it's degraded, every Edit/Write/Bash call fails with "temporarily unavailable, so auto mode cannot determine the safety of X". Read-only tools (Read, Grep, Glob) are unaffected, since they don't route through the classifier.

- Don't retry the same blocked mutating call more than twice. The outage doesn't clear on its own timeline you can guess.
- Surface the outage explicitly and offer the fix: switch this session to `/permission default` (prompts per-call instead of via classifier) or `/sandbox` (OS-level isolation, no classifier dependency at all) as a workaround, then switch back once the outage clears.
- Keep working on any read-only sub-task while waiting, don't block the whole turn on a retry loop.

**Why**: recurring classifier outages blocked Edit/Bash mid-task multiple times in one session; `/permission default` reliably unblocked it each time. `/sandbox` is the harder-guarantee alternative since it doesn't depend on a model being up at all.

## Why

Multiple `/morning` runs stalled on missing local deps (icalBuddy, Notion MCP). Multiple sessions burned cycles on auth issues mid-task. Sandbox blocks caused per-call disable-and-retry cycles. Catching all three upfront keeps flow. A silently-empty `settings.json` (2026-08-05) disabled every hook and permission rule for 2+ days with zero visible error, added the fourth check above for the same reason.

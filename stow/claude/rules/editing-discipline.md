---
description: Verify before edit; grep before adding to config; never invent commands or fabricate citations; minimal-edit principle
visibility: public
---

# Editing Discipline

<!-- [tackroom] adopted 2026-05-09 -->

Do not modify files to test a hypothesis. Investigate first, propose, get confirmation, then edit minimally.

## Verify before edit

For diagnostic work (broken plan, failing test, mystery error):

1. Reproduce or confirm the failure first.
2. State your hypothesis with evidence (file:line citations, log excerpts, command output).
3. For non-obvious fixes, wait for confirmation before editing.
4. If the hypothesis is uncertain, say so and ask. Do not speculate-then-revert.

**Why**: Multiple sessions had speculative edits to atmos templates, watchlist modules, and config files that were later reverted, leaving the original problem unresolved.

## Grep before adding to config files

Before adding a hook, permission, MCP entry, or any config block to `settings.json`, `.claude.json`, `.coderabbit.yaml`, or any structured config:

- Grep for the key or identifier first.
- If a similar entry exists, propose modifying it rather than adding a parallel one.
- Show me the existing entry before suggesting the change.

**Why**: Caused duplicate hook entries that needed cleanup later.

## Verify before citing (commands, URLs, conventions)

When asserting that a CLI command, slash command, MCP tool, project convention, API shape, or documentation URL exists, ground the claim in an actual source. Do not generate a plausible-looking one from memory.

- **Commands or flags**: confirm via `--help`, official docs, or recent output. Never compose a command that "sounds right." If unsure, say so.
- **Project conventions**: grep for the pattern before claiming it is a convention. If you cannot find it, say so.
- **Third-party docs / API URLs**: link to a real URL or fetch it. Do not fabricate URLs.
- **Reviewer suggestions** (CodeRabbit, human reviewers): verify against actual library or CLI behavior before applying.
- **Memory-sourced claims**: if a memory file claims X is a convention, confirm X still exists in code before repeating the claim.

**Why**: Hallucinated commands (e.g., `/config reload`), fabricated URLs, and stale memory citations waste time and erode trust. Before writing "per the X convention" or "run `/foo`", ask: where is the evidence? If you have not looked in the last few seconds, look now.

## Verify before declaring code or resources "dead"

Before claiming a function, lambda, module, S3 bucket, IAM role, repo, or any resource is unused, dead, or safe to delete:

1. Search by **at least two independent methods**. Example: ripgrep on the symbol name across the org, **and** check CloudTrail / CloudWatch logs / GitHub search for recent invocations. A single empty grep is not proof.
2. State the evidence: "checked X (result), checked Y (result), therefore the resource appears unused."
3. **Time-box** the claim: "no invocations in the last 90 days per CloudTrail" is verifiable; "this lambda is dead" is overclaiming.
4. If the resource is reachable from any external trigger (EventBridge rule, scheduled cron, SNS subscription, API Gateway, IAM trust policy), surface that and do not call it dead until the trigger is also confirmed inactive.

**Why**: Multiple sessions made overconfident claims ("this lambda is dead", "the second lambda is unused", "confirmed exfiltration") that were later reversed. The reversal is more costly than checking twice up front. Same pattern for "this user has no access" claims, see `aws-identity-source.md` for why Okta alone is insufficient evidence.

## Check tool encoding contracts before pre-processing content

Before base64-encoding, escaping, or otherwise pre-transforming content passed to a GitHub/Atlassian/Notion/Google API tool, check whether the tool already does that transform internally (read the tool's schema/description or test with a 1-line file first). Never pre-encode on the assumption a tool needs it.

- Same caution for literal `\n` escapes in body content meant for a document API. Pass real newlines, not escaped ones, unless the schema says otherwise.

**Why**: A GitHub tool call pre-base64-encoded `providers.tf` for a tool that encodes internally, corrupting the file into a garbled string ("wtf, the providers.tf now contains some crazy string of text").

## Minimal-edit principle

- The smallest change that fixes the problem is the right change.
- No unrequested refactors, comment cleanups, formatting passes, or "while I am here" improvements.
- If you spot something worth fixing alongside, surface it as a separate proposal before touching it.

## Preview destructive command flags

Before running `sed -i`, `awk -i inplace`, `perl -pi -e`, `> file` (clobber), `truncate`, or similar in-place edits:

- For `sed`/`awk`/`perl`: run WITHOUT the in-place flag first, pipe to head/less, verify output looks right, then re-run with the flag.
- Prefer `sponge` (from moreutils) for safer atomic in-place: `cmd file | sponge file`.
- Confirm the file is committed or backed up before destructive edits to it.

**Why**: A bad `sed` command emptied a workflow file in a prior session, recovered only via git. Preview is cheap; recovery is not.

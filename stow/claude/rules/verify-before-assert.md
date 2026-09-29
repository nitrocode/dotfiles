---
description: Cite evidence for infra/ticket-state claims; re-derive risk claims before approving; verify authorship before attributing
visibility: public
---

# Verify Before You Assert

Insights review (2026-08-02) found a recurring pattern: a confident claim shipped before the underlying fact was checked, and the user became the verification step instead of me.

## Cite evidence for factual claims

- Never state a fact about infra, IAM, test coverage, or ticket state without first running the command or API call that proves it.
- Cite the command or link alongside the claim, not just the conclusion.
- If a claim can't be verified in the current session, mark it `UNVERIFIED` explicitly rather than asserting it as fact.

## Re-derive risk claims before recommending approval

- Before recommending PR approval, independently re-check every risk claim in the diff yourself.
- Don't rely on CodeRabbit output, prior comments, or emoji reactions as evidence of anything having been checked.
- For migrations or policy changes affecting many components, validate all affected components, not just the ones shown in the diff.

## Verify authorship before attributing

- Don't attribute a Slack reaction or comment to a person without checking the actual author field.

## Re-read after publishing

- After publishing a Confluence/Notion page or Jira comment, re-read it back and confirm the content rendered as intended before treating the task as done.

## AWS credential/resource usage claims: check infra before trusting silence

- Before asserting an IAM user/key is "stale" or "active" from logs alone, check running infrastructure first (EC2 tags, Secrets Manager secret names/descriptions, Lambda/ECS configs). It's faster and often settles the question outright.
- Know which services CloudTrail can even log before treating an absence of events as evidence of inactivity. Data events only exist for `AWS::S3::Object`, `AWS::Lambda::Function`, `AWS::DynamoDB::Table`; Kinesis and several other services' data-plane calls are structurally unloggable, no config change fixes that.
- For IAM Access Advisor, read the per-action `TrackedActionsLastAccessed[].LastAccessedTime`, not the parent `LastAuthenticated`. The service-level field updates on any action in that service, tracked or not, and can show "today" while the specific action you're citing was last used months ago.
- See `reference_aws_credential_usage_investigation` memory for the full ordered checklist.

**Why**: a Cycode PR review misattributed the user's own 👀 reactions as a colleague's input and nearly got recommended for approval before the risk claims were independently checked; a Confluence page shipped with unverified claims and needed a follow-up audit.

**Why (AWS section)**: an IAM access review misread Access Advisor's service-level timestamp as action-level truth and took several correction cycles to resolve, when checking running EC2 infrastructure first would have caught it in one pass.

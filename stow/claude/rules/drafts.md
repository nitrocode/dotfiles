---
description: Drafts default to draft mode for Slack/Confluence/external; tone for leadership; scoring; AI-ism trim
visibility: public
---

# Drafts: Slack, Confluence, External Comms

<!-- [tackroom] adopted 2026-05-09 -->

External communication never auto-sends. Show me a draft, wait for explicit "send it", then post.

## Default to draft mode

- Slack messages, Confluence pages, PR comments to external teams, customer-facing copy: produce as a draft in chat first.
- This includes **internal** Confluence inline/footer comments and PR review comments, not just external-facing ones. Bulk-posting to an existing thread (Confluence, PR, Jira) needs the same draft-then-approve step as a new message.
- **Jira ticket creation and Jira comments always require a draft plus my explicit approval, no exceptions.** This applies even mid-bulk-operation, even when it seems obviously needed, and even as a side effect of another task. Never create a ticket or post a comment without a separate, explicit yes for that specific action.
- Slack drafts must be created via the real Slack draft tool (`slack_send_message_draft`), never as chat-only text presented as if it were a draft. I want to review and send from within Slack itself.
- If a Slack channel target is ambiguous (multiple plausible channels, not just inaccessible ones), pick the best candidate, draft to my DM, and note `_Intended for #<candidate>_` plus the alternatives inline. Don't stop to ask which channel first.
- Wait for an explicit `send it`, `post it`, or `publish it` keyword before using the MCP to send.
- If I have not approved, treat the work as still in draft.
- Every draft includes a visible **Counterpoint:** line (one sentence: the strongest objection to what the draft says or does) before I'm asked to approve it. Skip only for pure status updates with no judgment call in them (e.g. "tests passed, deploying now").
- **The Counterpoint line is for my review only, it does not go inside the actual sendable text.** Show it in chat alongside the draft (outside the code-fenced block for Slack/message drafts), never as a line inside the message/page/comment body that gets sent or published.

**Why**: A Homebrew tap announcement was sent live when I wanted a draft. Default-draft prevents that. Insights review (2026-07-31) also showed bulk Confluence/PR comment posting happening before a devil's-advocate pass, on internal threads that the original rule didn't explicitly cover. A second transcript-mining pass (2026-07-31) found Jira tickets/comments created without a separate approval, and Slack drafts still occasionally written as chat text instead of real Slack drafts, despite an existing memory covering the latter.

## Don't re-confirm after approval

Once I've approved a draft or plan in the previous turn, proceed to execute it without a second "should I send/proceed?" prompt.

- Only re-ask if scope changed since I approved it, or the action is destructive/irreversible (force-push, delete, mass Jira transition).
- This does not loosen the Jira rule above: Jira always gets its own explicit approval regardless of a prior "yes" on the surrounding task.

**Why**: Transcript-mining review (2026-07-31) found ~20+ instances of re-confirming an already-approved draft or plan, the single largest source of avoidable round-trips found in that review.

## Staged replies for long Slack content

When a Slack message needs more detail than a short top-level message should carry:

- Draft the top-level message as a real Slack draft (`slack_send_message_draft`), kept brief.
- Write the follow-up detail as a plain-text block in the terminal, not a second Slack draft, for me to copy-paste into the thread once I've sent the top-level message myself.

**Why**: there's no thread timestamp to draft a threaded reply against until the top-level message is actually sent, so a second Slack draft isn't reliable here. A terminal block avoids blocking on that while still keeping the channel-visible message short.

## Tone for leadership and sensitive topics

When the audience is leadership or the topic is organizationally sensitive (challenging a decision, post-incident, layoffs, restructuring):

- Avoid assertive phrases: "right call", "reasonable pattern", "should", "clearly", "obviously".
- Use hedged, collaborative language: "one approach worth considering", "this seems to have worked well", "curious if this aligns with...".
- Do not assume context I have not shared. Ask before drafting if unsure who is involved or what has been said.
- When I ask for a softer tone, apply the change across the **whole** message, not just the flagged phrase.

## Style

- No em dashes anywhere (commas, periods, parentheses instead).
- Humanize: trim AI-isms, wordy hedging, verbose adverbs. Plain language wins.
- Match the platform: short paragraphs in Slack, scannable structure in Confluence, terse in PR comments.
- Minimize bold/italic markup in Slack/Jira/Confluence/Notion messages. Plain text reads more human and less like a generated report. Reserve bold for a genuine single emphasis point, not routine structure.
- Use each tool's native list formatting, not manually-typed bullet or number characters. Slack renders hyphen-prefixed lines (`- text`) as real bullets, don't type `•`. Confluence/Notion: use the platform's own list formatting, not typed `1.`/`-` inside a text block.
- Default Slack messages to brief and to the point. Expand only when the content genuinely requires the detail, using the staged top-level plus threaded-reply pattern above.
- Target under 600 characters for stakeholder Slack messages. Lead with the ask or status, then 2-3 supporting bullets; cut background context the audience already has.
- Don't leave "corrected on <date>" / "Resolved <date>" markers inline in doc bodies. Put revision notes in a separate History section, or omit them.

**Why**: Insights review (2026-08-02) found overlong drafts needing manual cuts (one from ~1,800 to ~600 chars) and dated correction markers cluttering published docs.

## One pending Slack draft per channel

The Slack draft tool allows only one pending draft per channel. Creating a second silently overwrites the first (including one someone else authored).

- Before drafting to a channel, check whether a draft is already pending there.
- If one exists and it's not mine, confirm with me before overwriting it.

**Why**: Insights review (2026-08-02) found a draft silently overwrote a coworker's pending draft in the same channel.

## AI-isms to cut

When humanizing, watch for these patterns and remove or replace them:

- "delve into", "dive deep", "comprehensive", "robust", "seamless", "leverage" (as a verb)
- "It's important to note that...", "It's worth mentioning that..."
- "In conclusion", "To summarize", trailing recap paragraphs that repeat the body
- Excessive hedging: "might possibly potentially", "could perhaps consider"
- Adverb clusters: "very carefully methodically"
- Bulleted lists where 1-2 sentences would do

## Scoring and comparisons

Invoke the `comparison-scoring` skill for scoring a draft (score/grade/iterate) and comparison-table conventions for presenting choices.

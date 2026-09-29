<!-- visibility: public -->

## Template Variables

| Placeholder | Description |
|---|---|
| `{{SKILL_NAME}}` | Slug name of the skill (e.g. `distill`, `capture-spec`, `snapshot`) |
| `{{SKILL_VERB}}` | Active verb for what the skill does (e.g. "extract", "distill", "capture") |
| `{{SOURCE_TYPE}}` | What the skill processes (e.g. "prompt", "design decision", "code review feedback") |
| `{{OUTPUT_TYPE}}` | What the skill produces (e.g. "reusable template", "specification", "playbook") |
| `{{ARTIFACT_NOUN}}` | Singular noun for the output (e.g. "template", "spec", "playbook") |
| `{{LIBRARY_DIR}}` | Filesystem path where artifacts are saved (e.g. `~/.claude/prompts`) |
| `{{INDEX_FILE}}` | Full path to the library index (e.g. `~/.claude/prompts/index.md`) |
| `{{RUBRIC_FILE}}` | Full path to the scoring rubric |
| `{{RUBRIC_DIM_COUNT}}` | Number of rubric dimensions |
| `{{MAX_SCORE}}` | Maximum rubric score (`{{RUBRIC_DIM_COUNT}}` × 10) |
| `{{AUDIENCE_DESCRIPTION}}` | Who uses this skill and why |
| `{{FIRST_CUSTOMER_SCENARIO}}` | One concrete sentence: who, intent, outcome |
| `{{EXAMPLE_USE_CASES}}` | 3–5 bullet examples of what this skill handles |
| `{{OUT_OF_SCOPE_ITEMS}}` | 3–5 bullet items explicitly excluded |
| `{{WORD_LIMIT}}` | Maximum word count for the generated artifact |

---

# /{{SKILL_NAME}}

**Audience:** {{AUDIENCE_DESCRIPTION}}

**First customer scenario:** {{FIRST_CUSTOMER_SCENARIO}}

**Example use cases this skill handles:**
{{EXAMPLE_USE_CASES}}

**Out of scope — do not {{SKILL_VERB}}:**
{{OUT_OF_SCOPE_ITEMS}}

**Effort budget:** Complete the full flow in a single pass. Keep the generated {{ARTIFACT_NOUN}} under {{WORD_LIMIT}} words. If the source is unusually long, summarize repeated sections rather than extracting verbatim.

**Announce:** "Using /{{SKILL_NAME}} to {{SKILL_VERB}} a {{OUTPUT_TYPE}}."

## Step 1: Mode Detection

Examine the message that invoked this skill:

- **Paste mode:** User included a substantial block of text in the same message. Use that as the source {{SOURCE_TYPE}}.
- **Session mode (default):** No pasted content. Scan the last 20 conversation turns. Find the most prominent {{SOURCE_TYPE}} the user wrote, refined, or asked you to critique. If multiple candidates exist, list them (one line each) and ask which to {{SKILL_VERB}}.

State: "Source: [paste / session — brief description]"

## Step 2: Extract and Transform

Produce a generalized {{ARTIFACT_NOUN}} from the source {{SOURCE_TYPE}}:

1. Replace all project-specific proper nouns, names, domains, URLs, and concrete values with `{{PLACEHOLDER_NAME}}` in SCREAMING_SNAKE_CASE.
2. Replace specific numeric values (counts, dates, sizes) unless they are universal constraints.
3. Preserve all structural elements: headers, section order, tone, length signals, markdown formatting.
4. Preserve domain-agnostic constraints verbatim.
5. At the TOP, add a `## Template Variables` section listing every `{{PLACEHOLDER}}` with a one-line description.

**Quality bar — a good {{ARTIFACT_NOUN}} must:**
- Use the minimum placeholders necessary (prefer one `{{ORG_NAME}}` over five near-identical variants)
- Have unambiguous placeholder names (reader must know what value to supply without guessing)
- Preserve the original's intent and constraints — do not accidentally generalize away a critical constraint
- Be instantly recognizable as the same structure after substitution

Output the full {{ARTIFACT_NOUN}} in a markdown code block.

## Step 3: Score

Read `{{RUBRIC_FILE}}`. Score the generalized {{ARTIFACT_NOUN}} (not the original) on all {{RUBRIC_DIM_COUNT}} dimensions.

Display immediately after the {{ARTIFACT_NOUN}}:

```
## Score: XX/{{MAX_SCORE}} (YY%)

| # | Dimension | Score | Note |
|---|-----------|-------|------|
[one row per dimension, last row = Reusability with 3–5 concrete use cases]

**Total: XX/{{MAX_SCORE}} (YY%)**
```

If total < 70%: flag the 3 lowest-scoring dimensions with specific additions that would raise each.

**Reusability gate:** If Reusability scores < 5, warn: "This {{ARTIFACT_NOUN}} scores low on reusability. Consider generalizing further or saving as a reference rather than a {{ARTIFACT_NOUN}}."

## Step 3b: Self-Check Before Saving

Re-read the generated {{ARTIFACT_NOUN}} and verify:

1. **Placeholder audit:** Every `{{PLACEHOLDER}}` is unambiguous — a new user could fill it in without additional context.
2. **Intent check:** The {{ARTIFACT_NOUN}} preserves the original's core goal and constraints. Nothing critical was accidentally generalized away.
3. **No secrets:** No API keys, tokens, passwords, email addresses, or internal URLs.
4. **Conciseness:** Under {{WORD_LIMIT}} words. If over, identify and compress the most verbose section.

Fix any failures before asking for the slug.

## Step 4: Save

Ask: "Topic name for this {{ARTIFACT_NOUN}}? (slug format) — or type 'skip' to discard."

If user types 'skip': acknowledge and stop.

Check `{{INDEX_FILE}}` for an existing row matching that topic:

**New topic:** version = `1.0.0`. Display: slug, version, score, first 3 lines of {{ARTIFACT_NOUN}}. Ask: "Saving as v1.0.0 — confirm?"

**Existing topic:**
- Show existing entry (version + score).
- Ask: "Patch (wording only), minor (new content or placeholders), or major (structure or rubric change)?"
- Increment accordingly. Display summary. Ask: "Saving as v[X.Y.Z] — confirm?"

Write both files:

**`{{LIBRARY_DIR}}/templates/<topic>-v<semver>.md`** — full {{ARTIFACT_NOUN}} with `## Template Variables` header.

**`{{LIBRARY_DIR}}/templates/<topic>-v<semver>.meta.json`:** scores, use_cases, notes (same schema as rubric output).

Update `{{INDEX_FILE}}`: add or update the row for this topic (latest version only).

## Step 5: Apply (Optional)

Ask: "Fill this {{ARTIFACT_NOUN}} now? I'll prompt you for each placeholder."

If yes:
1. Iterate through `## Template Variables` in order.
2. For each `{{PLACEHOLDER}}`, ask: "[PLACEHOLDER_NAME]: "
3. Substitute all occurrences.
4. Output the filled {{ARTIFACT_NOUN}} in a markdown code block.
5. Stop. Do not save the filled version unless the user explicitly asks.

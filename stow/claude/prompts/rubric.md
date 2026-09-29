<!-- visibility: public -->

# Prompt Quality Rubric

5 dimensions, each scored 0-10. Total /50 (equally weighted). Display as raw score and percentage.

**Score guide:**
- **0-2** Absent or broken
- **3-5** Partial, present but vague
- **6-8** Present and functional
- **9-10** Exemplary

---

## 1. Clarity

*Does the prompt state a single, unambiguous goal with success criteria?*

- 0: Goal implicit or contradictory
- 5: Goal present but multi-interpretable
- 8: Single clear goal; reader knows what "done" looks like
- 10: Goal + explicit success criteria + named anti-goals

## 2. Structural Specifics

*Does the prompt specify expected output format, length, and audience?*

- 0: No format guidance, no audience signal
- 5: Vague ("use markdown", "for the team")
- 8: Format specified (sections, length, tone) + audience named
- 10: Example skeleton + audience with knowledge level + how output will be used

## 3. Quality Bar

*Does the prompt define what "good" looks like with concrete checks?*

- 0: No quality signal
- 5: Generic ("make it thorough")
- 8: Specific criteria (e.g., "each section must cite a source")
- 10: Embedded checklist or rubric Claude can self-check against

## 4. Stopping Criterion

*Does Claude know when to stop and what to hand off?*

- 0: No termination signal; open-ended
- 5: Implied stopping point
- 8: Explicit "done when X" with completion output format
- 10: Done-when + handoff instruction (what comes next, who picks up)

## 5. Reusability

*How many distinct use cases can this template serve without modification?*

- 0: Single use case; no placeholders
- 3: 2 use cases with heavy placeholder substitution
- 5: 3-4 use cases; placeholders do the work
- 8: 5+ use cases across different orgs or domains
- 10: Domain-agnostic; any team encountering this problem class can apply it

At score time, list 3-5 concrete example use cases.

---

## Notes on v2 rubric

Reduced from 15 to 5 dimensions on 2026-05-12. The dropped dimensions (Org Context, Audience, Content Scope, First Customer, Auth Model, Auto-Update, Deliverable Boundary, Rubric Provided, Token-Cost Expectation, Self-Feedback Meta) are mostly absorbed into Structural Specifics (audience, format) and Quality Bar (criteria, self-check) or Stopping Criterion (boundary, handoff).

Older scored templates (`homebrew-tap`, `extraction-skill`) were scored against the v1 /150 rubric. Their scores are stale. Re-score via `/distill` if precision matters.

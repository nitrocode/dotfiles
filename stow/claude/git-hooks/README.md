<!-- visibility: public -->

# ~/.claude/git-hooks/

Global git hooks. One canonical location, edits apply everywhere immediately.

## Install (once)

```bash
git config --global core.hooksPath ~/.claude/git-hooks
```

This overrides per-repo `.git/hooks/`. Most modern repos run pre-commit via Husky / pre-commit / lefthook (which read project config, not `.git/hooks/`), so coexistence is usually clean. If a repo specifically uses `.git/hooks/`, set `core.hooksPath` for just that repo with `git config --unset core.hooksPath` followed by `git config core.hooksPath .git/hooks`.

## What's here

| Hook | Purpose |
|---|---|
| `prepare-commit-msg` | Appends `Refs: <TICKET>` trailer based on branch name; warns on non-Conventional Commits subjects. See header comments in the file for config knobs. |

## Iteration

Edit the hook file in place. Changes apply to the next commit.

## Bypass

- Set `SKIP_TICKET=1` or `SKIP_CC_WARN=1` env var before a single commit.
- Remove `core.hooksPath` globally to disable entirely: `git config --global --unset core.hooksPath`.

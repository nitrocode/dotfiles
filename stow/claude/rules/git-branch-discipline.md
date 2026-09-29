---
description: Always ask whether to edit a repo's default branch directly or use a worktree
visibility: public
---

# Git Branch Discipline

## Ask before choosing main vs. worktree

Before any `Edit`/`Write` that touches a git repo, if the current branch is the default branch (`main`/`master`), ask whether to make the change directly there or create a worktree/feature branch first. Do not default to either choice, even when a repo-level hook blocks direct edits to main and forces a worktree workaround, still ask, since the workaround itself (edit in worktree, copy back to main) is a choice the user should confirm.

- A "yes, main is fine" answer in one session does not carry forward. Ask again next time, unless a project's own CLAUDE.md states a standing policy for that repo specifically.
- This applies laptop-wide, across every repo, not just one project.

**Why**: Repeated ambiguity over whether to edit `main` directly or spin up a worktree, including cases where a hook forced a worktree-then-copy-back workaround without being asked first.

# Agent instructions

This repo is **public**. Everything committed here is published.

## Never commit employer or org-specific content

- No employer names, internal repo/org names, ticket keys, account IDs, tenant IDs, Slack IDs, internal hostnames, emails, or 1Password item names.
- Use neutral placeholders in tests and examples: `acme/foo`, `PROJ-123`, `example.atlassian.net`, `you@example.com`, `123456789012`.
- Work-only hooks, scripts, and tests stay as real (unstowed) files under `$CLAUDE_CONFIG_DIR`. Don't stow them here.
- Machine or org config goes in untracked `.local` overlays (`~/.zshrc.local`, `~/.gitconfig.local`), never in this repo.
- Public vendor tool names (atmos, terraform, okta CLI, etc.) are fine.

## Leak guard

`stow/config/git/leak-guard.py` runs on every commit and push through config-based hooks in `stow/shell/.gitconfig`. It reads the untracked denylist at `~/.config/git/leak-guard.local`.

- If it blocks, fix the content. Don't bypass with `LEAK_GUARD_SKIP=1` or `--no-verify` unless the user explicitly says the match is a false positive.
- Never add the denylist terms themselves to any tracked file, including tests and docs.
- Git hooks don't cover pushes that skip git (GitHub web UI, `gh api` file writes, GitHub MCP). Use plain `git push` for this repo.

## Tests

- `python3 -m pytest stow/config/git/tests stow/claude/scripts/tests`
- `bash stow/claude/scripts/run-hook-tests.sh` for the bash hook suites

<!-- visibility: public -->

# ~/.claude/scripts/

Personal cross-session script library. Not tied to any repo, not committed.

## Purpose

A stable home for scripts that are too long to inline (>20 lines) or that you want available across Claude Code sessions and machines (via dotfiles sync, manual rsync, etc.).

## Conventions

See `~/.claude/rules/reusable-scripts.md` for the full version. Quick reference:

- 20+ lines or likely-to-reuse goes here, not `/tmp/`
- Bash: `set -euo pipefail`. Python: docstring + `if __name__ == "__main__"`.
- Executable bit set; descriptive names; 3-5 line header explaining purpose.

## Layout

Flat for now. Group into subdirs if it grows past ~30 scripts (suggested groupings: `aws/`, `jira/`, `slack/`, `terraform/`, `confluence/`).

## Notable scripts

Keep this list in sync when adding non-trivial scripts. A future shell (Claude or human) should be able to scan this file to know what already exists before reinventing.

| Script | Purpose | Docs |
|---|---|---|
| `trufflehog-scan.sh` | Filesystem secret scan with shared exclude / allowlist / FP-filter config. Default mode surfaces verified + unverified-high-signal findings, deduped by sha1. Run with `--help` for flags. | `trufflehog/README.md` |
| `rotate-byline.sh` | Rotates the Co-Authored-By byline string used in commit messages. | (header comment) |
| `observe-registry-discover.py` | Enumerates every Observe dataset (id, name, kind, description, schema) via the GraphQL meta API, writes to `out/observe-registry-<date>.json`. Phase 1 of the Observe dataset registry; run with `uv run --with requests python3 observe-registry-discover.py`. | `observe-registry-design.md`, `observe-registry-api-notes.md` |

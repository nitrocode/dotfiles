#!/usr/bin/env python3
"""Global git hook: block denylisted strings from reaching non-work remotes.

Registered for every repo via config-based hooks in ~/.gitconfig
(hook.<name>.command / hook.<name>.event, git 2.54+), so it runs alongside
each repo's own .git/hooks (e.g. pre-commit) instead of replacing them.

Whether a repo is guarded is decided by remote URL, not identity or path:
a repo whose remotes all match [allow-remotes] (e.g. the work org) is skipped,
everything else is checked. pre-push is the authoritative gate since it knows
the real destination; pre-commit and commit-msg catch problems earlier.

Patterns live in an untracked file so the denylist itself is never published:
    ${LEAK_GUARD_CONFIG:-~/.config/git/leak-guard.local}

    [deny]            # one case-insensitive Python regex per line
    examplecorp
    TICKET-[0-9]+
    [allow-remotes]   # regexes matched against remote URLs
    github\\.com[:/]examplecorp/

Missing config fails closed. Bypass once with LEAK_GUARD_SKIP=1.

Usage (called by git): leak-guard.py pre-commit | commit-msg FILE | pre-push REMOTE URL
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ZERO_SHA = "0" * 40
DEFAULT_CONFIG = Path.home() / ".config" / "git" / "leak-guard.local"


def load_config(path: Path) -> tuple[list[re.Pattern], list[re.Pattern]]:
    """Parse the INI-like config into (deny, allow_remotes) regex lists."""
    sections: dict[str, list[re.Pattern]] = {"deny": [], "allow-remotes": []}
    current = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            continue
        if current in sections:
            sections[current].append(re.compile(line, re.IGNORECASE))
    return sections["deny"], sections["allow-remotes"]


def git(*args: str) -> str:
    """Run a git command in the current repo and return stdout."""
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def is_allowed(url: str, allow: list[re.Pattern]) -> bool:
    """True if the remote URL matches any allow-remotes pattern."""
    return any(p.search(url) for p in allow)


def find_hits(lines, deny: list[re.Pattern], label: str) -> list[str]:
    """Return 'label: matched -> line' strings for every denied match."""
    hits = []
    for text in lines:
        for p in deny:
            m = p.search(text)
            if m:
                hits.append(f"  {label}: '{m.group(0)}' in: {text.strip()[:160]}")
                break
    return hits


def diff_hits(patch: str, deny: list[re.Pattern]) -> list[str]:
    """Scan a unified diff: added lines, plus new file paths. Removed lines are ignored."""
    hits: list[str] = []
    path = "?"
    for line in patch.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else line[4:]
            hits += find_hits([path], deny, f"path {path}")
        elif line.startswith("rename to "):
            hits += find_hits([line[10:]], deny, f"path {line[10:]}")
        elif line.startswith("+") and not line.startswith("+++"):
            hits += find_hits([line[1:]], deny, path)
    return hits


def check_pre_commit(deny, allow) -> int:
    """Scan the staged diff; warn-only when the repo has no remotes yet."""
    urls = [u for u in git("remote", "-v").split() if "/" in u or ":" in u]
    if urls and all(is_allowed(u, allow) for u in urls):
        return 0
    staged = git("diff", "--cached", "--name-only", "--diff-filter=ACMR").splitlines()
    hits = [f"  {f}: '.local' overlay files are machine-specific, never commit them"
            for f in staged if Path(f).name.endswith(".local")]
    hits += diff_hits(git("diff", "--cached", "-U0", "--no-color", "-M"), deny)
    if not hits:
        return 0
    if not urls:
        report("warning (no remote yet, not blocking; pre-push will block)", hits)
        return 0
    return report("blocked commit", hits)


def check_commit_msg(msg_file: str, deny) -> int:
    """Scan the commit message, skipping git's comment lines."""
    lines = [ln for ln in Path(msg_file).read_text().splitlines() if not ln.startswith("#")]
    hits = find_hits(lines, deny, "commit message")
    return report("blocked commit message", hits) if hits else 0


def check_pre_push(remote: str, url: str, stdin: str, deny, allow) -> int:
    """Scan every commit (message + added lines) that this push would publish."""
    if is_allowed(url, allow):
        return 0
    hits: list[str] = []
    for line in stdin.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        _, local_sha, _, remote_sha = parts
        if local_sha == ZERO_SHA:
            continue  # branch deletion publishes nothing
        rng = [local_sha, "--not", f"--remotes={remote}"] if remote_sha == ZERO_SHA else [f"{remote_sha}..{local_sha}"]
        for sha in git("rev-list", *rng).split():
            msg = git("log", "-1", "--format=%B", sha).splitlines()
            hits += find_hits(msg, deny, f"commit {sha[:10]} message")
            patch = git("show", "--format=", "-U0", "--no-color", "-M", sha)
            hits += [h.replace("  ", f"  {sha[:10]} ", 1) for h in diff_hits(patch, deny)]
    return report(f"blocked push to {url}", hits) if hits else 0


def report(title: str, hits: list[str]) -> int:
    """Print findings to stderr; return 1 (block)."""
    print(f"leak-guard: {title}:", file=sys.stderr)
    print("\n".join(hits), file=sys.stderr)
    print("Fix the content, or bypass once with LEAK_GUARD_SKIP=1 if this is a false positive.", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    """Dispatch on the hook event passed as the first argument."""
    if os.environ.get("LEAK_GUARD_SKIP") == "1" or len(argv) < 2:
        return 0
    event = argv[1]
    if event not in ("pre-commit", "commit-msg", "pre-push"):
        return 0
    cfg = Path(os.environ.get("LEAK_GUARD_CONFIG", DEFAULT_CONFIG)).expanduser()
    if not cfg.is_file():
        print(f"leak-guard: config {cfg} not found; refusing (fail closed).\n"
              "Create it (see header of leak-guard.py) or set LEAK_GUARD_SKIP=1.", file=sys.stderr)
        return 1
    deny, allow = load_config(cfg)
    if event == "pre-commit":
        return check_pre_commit(deny, allow)
    if event == "commit-msg":
        return check_commit_msg(argv[2], deny)
    return check_pre_push(argv[2], argv[3], sys.stdin.read(), deny, allow)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

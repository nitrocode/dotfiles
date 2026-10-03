"""Tests for leak-guard.py, the global git hook that blocks denylisted strings.

Each test builds a throwaway repo (and bare remote where needed) under tmp_path
and runs the script the same way git's config-based hooks do.

Run: python3 -m pytest stow/config/git/tests/test_leak_guard.py -v
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "leak-guard.py"
ZERO = "0" * 40

CONFIG = """\
# comment lines and blanks are ignored
[deny]
acmecorp
SECRET-[0-9]+

[allow-remotes]
github\\.com[:/]acmecorp/
"""


def git(cwd, *args, **kw):
    """Run git in cwd with a fixed identity and return stdout."""
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                          capture_output=True, text=True, **kw).stdout.strip()


@pytest.fixture
def cfg(tmp_path):
    p = tmp_path / "leak-guard.local"
    p.write_text(CONFIG)
    return p


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "w"
    r.mkdir()
    git(r, "init", "-q", "-b", "main")
    # Disable any global hooks so setup commits don't trigger the real guard.
    git(r, "config", "core.hooksPath", "/dev/null")
    for name in ("leak-guard-commit", "leak-guard-msg", "leak-guard-push"):
        git(r, "config", f"hook.{name}.enabled", "false")
    git(r, "remote", "add", "origin", "git@github-personal.com:me/dotfiles.git")
    return r


def run(repo, cfg, *args, stdin="", env_extra=None):
    """Invoke the guard like git would; return CompletedProcess."""
    env = {**os.environ, "LEAK_GUARD_CONFIG": str(cfg)}
    env.pop("LEAK_GUARD_SKIP", None)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=repo, env=env,
                          input=stdin, capture_output=True, text=True)


def stage(repo, name, content):
    (repo / name).parent.mkdir(parents=True, exist_ok=True)
    (repo / name).write_text(content)
    git(repo, "add", name)


# --- pre-commit -------------------------------------------------------------

def test_pre_commit_blocks_denied_added_line(repo, cfg):
    stage(repo, "a.txt", "hello AcmeCorp world\n")
    r = run(repo, cfg, "pre-commit")
    assert r.returncode == 1
    assert "a.txt" in r.stderr and "acmecorp" in r.stderr.lower()


def test_pre_commit_passes_clean_change(repo, cfg):
    stage(repo, "a.txt", "nothing to see\n")
    assert run(repo, cfg, "pre-commit").returncode == 0


def test_pre_commit_regex_pattern(repo, cfg):
    stage(repo, "a.txt", "see SECRET-42\n")
    assert run(repo, cfg, "pre-commit").returncode == 1


def test_pre_commit_blocks_denied_path(repo, cfg):
    stage(repo, "tests/test-acmecorp-sync.sh", "clean body\n")
    r = run(repo, cfg, "pre-commit")
    assert r.returncode == 1
    assert "test-acmecorp-sync.sh" in r.stderr


def test_pre_commit_blocks_local_overlay_file(repo, cfg):
    stage(repo, ".zshrc.local", "export FOO=1\n")
    r = run(repo, cfg, "pre-commit")
    assert r.returncode == 1
    assert ".local" in r.stderr


def test_pre_commit_ignores_removed_lines(repo, cfg):
    stage(repo, "a.txt", "acmecorp\n")
    git(repo, "commit", "-qm", "seed", "--no-verify")
    stage(repo, "a.txt", "clean\n")
    assert run(repo, cfg, "pre-commit").returncode == 0


def test_pre_commit_skipped_for_allowed_remote(repo, cfg):
    git(repo, "remote", "set-url", "origin", "git@github.com:acmecorp/internal.git")
    stage(repo, "a.txt", "acmecorp is fine here\n")
    assert run(repo, cfg, "pre-commit").returncode == 0


def test_pre_commit_enforced_if_any_remote_not_allowed(repo, cfg):
    git(repo, "remote", "set-url", "origin", "git@github.com:acmecorp/internal.git")
    git(repo, "remote", "add", "public", "git@github.com:me/fork.git")
    stage(repo, "a.txt", "acmecorp\n")
    assert run(repo, cfg, "pre-commit").returncode == 1


def test_pre_commit_no_remote_warns_only(repo, cfg):
    git(repo, "remote", "remove", "origin")
    stage(repo, "a.txt", "acmecorp\n")
    r = run(repo, cfg, "pre-commit")
    assert r.returncode == 0
    assert "warning" in r.stderr.lower()


# --- commit-msg -------------------------------------------------------------

def test_commit_msg_blocks_denied_message(repo, cfg, tmp_path):
    msg = tmp_path / "MSG"
    msg.write_text("fix: thing for SECRET-7\n")
    assert run(repo, cfg, "commit-msg", str(msg)).returncode == 1


def test_commit_msg_ignores_comment_lines(repo, cfg, tmp_path):
    msg = tmp_path / "MSG"
    msg.write_text("fix: thing\n# On branch acmecorp-stuff\n")
    assert run(repo, cfg, "commit-msg", str(msg)).returncode == 0


# --- pre-push ---------------------------------------------------------------

@pytest.fixture
def pushed(repo, tmp_path):
    """Repo with one clean commit already on a bare remote."""
    bare = tmp_path / "remote.git"
    git(tmp_path, "init", "-q", "--bare", str(bare))
    git(repo, "remote", "add", "bare", str(bare))
    stage(repo, "a.txt", "clean\n")
    git(repo, "commit", "-qm", "clean", "--no-verify")
    git(repo, "push", "-q", "--no-verify", "bare", "main")
    return repo


def push_line(repo, remote_sha):
    head = git(repo, "rev-parse", "HEAD")
    return f"refs/heads/main {head} refs/heads/main {remote_sha}\n"


def test_pre_push_blocks_denied_diff_in_range(pushed, cfg):
    base = git(pushed, "rev-parse", "HEAD")
    stage(pushed, "b.txt", "acmecorp\n")
    git(pushed, "commit", "-qm", "add b", "--no-verify")
    r = run(pushed, cfg, "pre-push", "origin", "git@github.com:me/dotfiles.git",
            stdin=push_line(pushed, base))
    assert r.returncode == 1


def test_pre_push_blocks_denied_commit_message(pushed, cfg):
    base = git(pushed, "rev-parse", "HEAD")
    stage(pushed, "b.txt", "clean\n")
    git(pushed, "commit", "-qm", "chore: SECRET-99", "--no-verify")
    r = run(pushed, cfg, "pre-push", "origin", "git@github.com:me/dotfiles.git",
            stdin=push_line(pushed, base))
    assert r.returncode == 1


def test_pre_push_ignores_already_pushed_history(pushed, cfg):
    base = git(pushed, "rev-parse", "HEAD")
    stage(pushed, "b.txt", "clean\n")
    git(pushed, "commit", "-qm", "add b", "--no-verify")
    r = run(pushed, cfg, "pre-push", "origin", "git@github.com:me/dotfiles.git",
            stdin=push_line(pushed, base))
    assert r.returncode == 0


def test_pre_push_new_branch_scans_unpushed_commits(pushed, cfg):
    stage(pushed, "b.txt", "acmecorp\n")
    git(pushed, "commit", "-qm", "add b", "--no-verify")
    r = run(pushed, cfg, "pre-push", "bare", "git@github.com:me/dotfiles.git",
            stdin=push_line(pushed, ZERO))
    assert r.returncode == 1


def test_pre_push_allowed_destination_skips(pushed, cfg):
    base = git(pushed, "rev-parse", "HEAD")
    stage(pushed, "b.txt", "acmecorp\n")
    git(pushed, "commit", "-qm", "add b", "--no-verify")
    r = run(pushed, cfg, "pre-push", "origin", "https://github.com/acmecorp/internal.git",
            stdin=push_line(pushed, base))
    assert r.returncode == 0


def test_pre_push_branch_delete_is_ignored(pushed, cfg):
    line = f"(delete) {ZERO} refs/heads/old {git(pushed, 'rev-parse', 'HEAD')}\n"
    r = run(pushed, cfg, "pre-push", "origin", "git@github.com:me/dotfiles.git", stdin=line)
    assert r.returncode == 0


# --- config handling --------------------------------------------------------

def test_missing_config_fails_closed(repo, tmp_path):
    stage(repo, "a.txt", "clean\n")
    r = run(repo, tmp_path / "nope.local", "pre-commit")
    assert r.returncode == 1
    assert "LEAK_GUARD_SKIP" in r.stderr


def test_skip_env_bypasses(repo, tmp_path):
    stage(repo, "a.txt", "acmecorp\n")
    r = run(repo, tmp_path / "nope.local", "pre-commit", env_extra={"LEAK_GUARD_SKIP": "1"})
    assert r.returncode == 0


def test_unknown_event_is_noop(repo, cfg):
    assert run(repo, cfg, "post-checkout").returncode == 0

# dotfiles

My personal dotfiles when moving between computers

## Layout

Managed with [GNU Stow](https://www.gnu.org/software/stow/). Each directory under `stow/` is a package whose contents mirror its target directory.

| Package | Target | Contents |
|---|---|---|
| `stow/shell` | `~` | `.zshrc`, `.zshenv`, `.gitconfig`, `.vimrc`, `.curlrc`, `.nanorc`, `.gitignore_global`, `.tflint.hcl` |
| `stow/claude` | `$CLAUDE_CONFIG_DIR` (physical path) | generic Claude Code hooks, rules, scripts, prompts, agents, git-hooks |
| `stow/config` | `~/.config` | `mise.toml`, `git/ignore`, `gh-dash/`, `codexbar/`, `rtk/` |

`examples/claude/settings.example.json` shows a sanitized Claude Code `settings.json`. It's a reference, not stowed.

Everything else at the repo root (`common_aliases`, `vscode_settings.json`, `.gitconfig-*.example`, etc.) is reference material and isn't stowed.

## Install

```sh
brew install stow
cd ~/git/personal/github/dotfiles
stow -d stow -t ~ --no-folding shell
stow -d stow -t ~/.config --no-folding config
# ~/.claude may itself be a symlink; target the real directory so relative links resolve
stow -d stow -t "$(realpath "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")" --no-folding claude
```

Add `-n -v` to any command for a dry run first.

Always use `--no-folding`. Without it, stow may replace a whole directory (e.g. `~/.claude/hooks`) with one symlink, and any private file created there later would land inside this public repo.

## Private overlays

Org- or machine-specific config never goes in this repo. It lives in untracked `.local` files that the public files load last:

- `~/.zshrc.local`, sourced at the end of `.zshrc`
- `~/.gitconfig.local`, included at the end of `.gitconfig` (so its `includeIf` rules win)

## Leak guard

`~/.gitconfig` registers `~/.config/git/leak-guard.py` as a global pre-commit, commit-msg, and pre-push hook (git 2.54+ config-based hooks, so each repo's own `.git/hooks` still runs). It blocks denylisted strings in any repo whose remotes aren't all on an allowed list, decided by remote URL rather than identity or directory.

The denylist is never committed. Create `~/.config/git/leak-guard.local` on each machine:

```ini
[deny]
examplecorp
TICKET-[0-9]+

[allow-remotes]
github\.com[:/]examplecorp/
```

With no config file it fails closed. `LEAK_GUARD_SKIP=1 git commit ...` bypasses it once.

## Adding a file

```sh
# 1. copy the live file into the package at the same relative path
cp ~/.config/foo/bar.toml stow/config/foo/bar.toml
# 2. adopt: moves the live file into the package and symlinks it back
stow -d stow -t ~/.config --no-folding --adopt config
# 3. review before committing
git diff
```

## Before committing

`--adopt` and any tool that runs `git config --global` write through the symlinks into this repo. Check what changed before each commit:

```sh
git status
git diff
trufflehog filesystem stow examples --no-update
```

## New laptop checklist

* [ ] New osx or linux compatible laptop
* [ ] Choose directory for laptop, if windows/linux choose `agnostic/` which uses a VM, if osx, choose `macos/`
* [ ] Follow instructions to setup os specific apps
* [ ] Create a new ssh key per source code provider (github, gitlab, etc) - need script
    * [ ] Add key and password to password manager
* [ ] Create common directories - need script
* [ ] Configure browser settings
* [ ] What else ?

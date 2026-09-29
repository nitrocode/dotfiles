eval "$(/opt/homebrew/bin/brew shellenv)"

alias assume="source assume"

# Disable telemetry for cleaner LLM interactions
export DISABLE_TELEMETRY=1
export DISABLE_ANALYTICS=1

export CLAUDE_CONFIG_REAL_DIR="$HOME/protected/.myclaude"
# export CLAUDE_CONFIG_DIR="$HOME/protected/.myclaude"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CLAUDE_CODE_DEBUG_LOGS_DIR="$CLAUDE_CONFIG_DIR/debug"
export CLAUDE_CODE_PLUGIN_CACHE_DIR="$CLAUDE_CONFIG_DIR/plugins"
# export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1

export CCUSAGE_CONFIG=~/.config/claude/ccusage.json

# env-only exports, visible to every zsh (incl. non-interactive scripts).
# PATH edits stay in .zshrc: macOS path_helper reorders PATH after .zshenv.
export EDITOR=vim
export GOPATH=~/go
export BUN_INSTALL="$HOME/.bun"
export AWS_PAGER=""
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
export HOMEBREW_CASK_OPTS="--appdir=/Applications"
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_AUTO_UPDATE=1
export RUBYOPT="-W:no-deprecated"
# solve old terraform m1 arm issues
export GODEBUG=asyncpreemptoff=1
export RTK_TELEMETRY_DISABLED=1
# rtk hook rewrite/skip audit log (~/.local/share/rtk/hook-audit.log)
export RTK_HOOK_AUDIT=1

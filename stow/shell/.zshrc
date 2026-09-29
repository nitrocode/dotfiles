###### global .zshrc

#### source .zshrc_omz
export ZSH=~/.oh-my-zsh

ZSH_THEME="robbyrussell"

plugins=(
  asdf
  git
  extract
  z
  zsh-autosuggestions
  zsh-syntax-highlighting
  command-not-found
  zsh-history-substring-search
  safe-paste
)

PROMPT='$(kube_ps1)'$PROMPT

# skip oh-my-zsh's auto-update version check (network call on every shell start)
export DISABLE_AUTO_UPDATE="true"

export HIST_STAMPS="mm/dd/yyyy"
export HISTSIZE=10000000
export SAVEHIST=10000000

setopt BANG_HIST                 # Treat the '!' character specially during expansion.
setopt EXTENDED_HISTORY          # Write the history file in the ":start:elapsed;command" format.
setopt INC_APPEND_HISTORY        # Write to the history file immediately, not when the shell exits.
setopt SHARE_HISTORY             # Share history between all sessions.
setopt HIST_EXPIRE_DUPS_FIRST    # Expire duplicate entries first when trimming history.
setopt HIST_IGNORE_DUPS          # Don't record an entry that was just recorded again.
setopt HIST_IGNORE_ALL_DUPS      # Delete old recorded entry if new entry is a duplicate.
setopt HIST_FIND_NO_DUPS         # Do not display a line previously found.
setopt HIST_IGNORE_SPACE         # Don't record an entry starting with a space.
setopt HIST_SAVE_NO_DUPS         # Don't write duplicate entries in the history file.
setopt HIST_REDUCE_BLANKS        # Remove superfluous blanks before recording entry.
setopt HIST_VERIFY               # Don't execute immediately upon history expansion.

# Bracketed paste mode (safe for multi-line LLM output, default in zsh 5.1+)
# Prevents accidental execution when Claude Code pastes commands
# Verify by checking if zle_bracketed_paste is NOT unset
if [[ -z "${zle_bracketed_paste}" ]]; then
  autoload -Uz bracketed-paste-magic
  zle -N bracketed-paste bracketed-paste-magic
fi

# FZF integration for fast command history search and fuzzy finding
if [[ ! "$PATH" == */.fzf/bin* ]]; then
  export PATH="${PATH:+${PATH}:}$(brew --prefix)/opt/fzf/bin"
fi
[[ $- == *i* ]] && source "$(brew --prefix)/opt/fzf/shell/completion.zsh" 2> /dev/null

source $ZSH/oh-my-zsh.sh

# zplug setup archived - using oh-my-zsh for plugin management instead
# see ~/.zshrc_archive for historical zplug configuration

#### source .rc_osx
# GNU tools from Homebrew (hardcoded for Apple Silicon; fallback for other archs)
HOMEBREW_OPT="${HOMEBREW_PREFIX:-/opt/homebrew}/opt"
# Alternative: HOMEBREW_OPT="$(brew --prefix)/opt"  # if dynamic lookup needed
export PATH="$HOMEBREW_OPT/coreutils/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gnu-sed/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gnu-tar/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/grep/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gnu-indent/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gpatch/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/findutils/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gnu-time/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/libtool/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/make/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/gawk/libexec/gnubin:$PATH"
export PATH="$HOMEBREW_OPT/uutils-coreutils/bin:$PATH"
export PATH="$HOMEBREW_OPT/openssh/bin:$PATH"
# iterm2 completion
test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"

#### source .rc_code
# local bin
export PATH=~/bin:$PATH
export PATH=~/.local/bin:$PATH

# go stuff (GOPATH is set in .zshenv)
export PATH="$GOPATH/bin:$PATH"

# direnv
eval "$(direnv hook zsh)"

# FZF keybindings (history search, file finder)
if [[ -f "$(brew --prefix)/opt/fzf/shell/key-bindings.zsh" ]]; then
  source "$(brew --prefix)/opt/fzf/shell/key-bindings.zsh"
  # Ctrl+R for history search with FZF (replaces default reverse-i-search)
  # Ctrl+T for file search
fi

#### source .rc_misc
## misc alias
alias vi="vim"
alias ls="ls --color=auto -F --group-directories-first"
## ripgrep
alias rg="rg --hidden"

#### source .rc_functions
# base function for loadkeyswork and loadkeysfun
function loadkeys {
  ssh-add -D
  ssh_dir=${1:-~/.ssh/}
  echo "getting keys : $ssh_dir"
  # ignore directories, ignore public keys, soft links, known hosts and ssh config
  ls -F $ssh_dir | grep -v '/$' | grep -vE '.pub$|@$|^known_hosts$|config$' | while read key; do ssh-add -K $ssh_dir/$key; done
}

function loadkeyswork {
  led-backlight-osx
  loadkeys ~/.ssh/
  ssh-add -K ~/.ssh/work/*github
}

function loadkeysworks {
  led-backlight-osx
  loadkeys ~/.ssh/
  ssh-add -K ~/.ssh/work/*github
}

function loadkeysfun {
  led-backlight-osx
  loadkeys ~/.ssh/personal
}

#ASDF_HASHICORP_OVERWRITE_ARCH_TERRAFORM=arm64

asdftfi() {
  current_version_to_install="$*"
  # https://releases.hashicorp.com/terraform/1.0.1/
  # https://releases.hashicorp.com/terraform/1.0.2/
  last_version_before_arm="1.0.1"
  # sort algorithm puts the earliest version first
  # ref: https://stackoverflow.com/a/25731924
  get_earliest_version=$(printf '%s\n%s' "$last_version_before_arm" "$current_version_to_install" | sort -t '.' -k 1,1 -k 2,2 -k 3,3 -k 4,4 -g | head -1)
  # if the version is the same, that means it's below 1.0.1
  if [ "$get_earliest_version" = "$current_version_to_install" ]; then
    arch="amd64"
  else
    arch=$(uname -m)
  fi
  ASDF_HASHICORP_OVERWRITE_ARCH_TERRAFORM="$arch" asdf install terraform "$current_version_to_install"
  asdf local terraform "$current_version_to_install"
}

asdftf() {
  curdir="$(pwd)"
  module="$1"
  echo "cd $curdir/$module"
  cd $curdir/$module
  asdftfi $(terraform-config-inspect "." --json | jq -r '.required_core[0]' | grep -oP '[0-9].*')
  echo "terraform ${@:2}"
  terraform ${@:2}
  cd $curdir
}

function tfvars {
  export TF_VAR_terraform_repository=$(git config --get remote.origin.url | sed 's,^git@,,g' | tr ':' '/' | sed 's,.git$,,g')
  export TF_VAR_terraform_repository_dir=$(git rev-parse --show-prefix | sed 's,\/$,,g')
}

function tfstate-path {
  echo "s3://$(cat *.tf | hcledit attribute get terraform.backend.bucket | tr -d '"')/$(cat *.tf | hcledit attribute get terraform.backend.key | tr -d '"')"
}

function tfstate-tf {
  # aws s3 cp "s3://$(cat *.tf | hcledit attribute get terraform.backend.bucket | tr -d '"')/$(cat *.tf | hcledit attribute get terraform.backend.key | tr -d '"')" - | jq -M .terraform_version
  aws s3 cp $(tfstate-path) - | jq -M .terraform_version
}

#### source .rc_terraform
alias tfi="tfvars && tf init"
alias tfiu="tfi -upgrade"

# Renovate: always run with --dry-run by default to prevent accidental issue/PR creation
alias renovate="renovate --dry-run"

alias h="history"

export GPG_TTY=$(tty)

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
export PATH=$PATH:~/.kube/plugins/luksa

alias k=kubectl

# _tea_chpwd() { source <(tea -Eds) }
# add-zsh-hook -Uz chpwd _tea_chpwd  #tea

export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
eval "$(mise activate zsh)"

# cached to avoid shelling out to the binary on every shell start (~277ms);
# regenerate after upgrading kubectl-argo-rollouts:
#   kubectl-argo-rollouts completion zsh > ~/.zsh/completions/kubectl-argo-rollouts.zsh
[[ -s ~/.zsh/completions/kubectl-argo-rollouts.zsh ]] && source ~/.zsh/completions/kubectl-argo-rollouts.zsh

function ssl-check {
    openssl s_client -servername $1 -connect $1:443 | openssl x509 -noout -dates
}

#### cc-hooks aliases

# bun completions
[ -s "$HOME/.oh-my-zsh/completions/_bun" ] && source "$HOME/.oh-my-zsh/completions/_bun"

# bun
export PATH="$BUN_INSTALL/bin:$PATH"

# Basic cld alias
alias cld='$CLAUDE_CONFIG_DIR/plugins/marketplaces/cc-hooks-plugin/claude.sh'


# Session variants
alias c='claude update && claude'
alias cr='c --resume'
alias cn='c --name'
alias cw='c --worktree'

# Model shortcuts
alias ch='c --model claude-haiku-4-5'
alias co='c --model claude-opus-5-5 --permission-mode plan'
alias cop='co --permission-mode plan'
alias cs='c --model claude-sonnet-5'
alias csp='cs --permission-mode plan'

# Haiku with auto-mode-like permissions (expanded allow list, fewer prompts)
alias cha='ch --settings "$CLAUDE_CONFIG_DIR/settings-haiku-auto.json"'

# Haiku with all permissions bypassed (no prompts at all)
alias cha-full='cha --dangerously-skip-permissions'

#### Claude Desktop MCP enable/disable helpers
# Move an MCP server entry between claude_desktop_config.json (active) and
# claude_desktop_config.disabled.json (parked). Restart Claude Desktop after.
mcp-enable() {
  local cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  local off="$HOME/Library/Application Support/Claude/claude_desktop_config.disabled.json"
  [[ -z "$1" ]] && { echo "usage: mcp-enable <name>"; return 1; }
  jq -e --arg n "$1" '.mcpServers[$n]' "$off" >/dev/null || { echo "not found in disabled file: $1"; return 1; }
  jq --slurpfile off "$off" --arg n "$1" '.mcpServers[$n] = $off[0].mcpServers[$n]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  jq --arg n "$1" 'del(.mcpServers[$n])' "$off" > "$off.tmp" && mv "$off.tmp" "$off"
  echo "enabled $1 — restart Claude Desktop"
}

mcp-disable() {
  local cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  local off="$HOME/Library/Application Support/Claude/claude_desktop_config.disabled.json"
  [[ -z "$1" ]] && { echo "usage: mcp-disable <name>"; return 1; }
  jq -e --arg n "$1" '.mcpServers[$n]' "$cfg" >/dev/null || { echo "not found in active config: $1"; return 1; }
  jq --slurpfile cfg "$cfg" --arg n "$1" '.mcpServers[$n] = $cfg[0].mcpServers[$n]' "$off" > "$off.tmp" && mv "$off.tmp" "$off"
  jq --arg n "$1" 'del(.mcpServers[$n])' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  echo "disabled $1 — restart Claude Desktop"
}

mcp-list() {
  local cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  local off="$HOME/Library/Application Support/Claude/claude_desktop_config.disabled.json"
  echo "active:";   jq -r '.mcpServers | keys[] | "  - \(.)"' "$cfg"
  echo "disabled:"; jq -r '.mcpServers | keys[] | "  - \(.)"' "$off"
}

alias npm='npq-hero'
alias pnpm="NPQ_PKG_MGR=pnpm npq-hero"
alias yarn="NPQ_PKG_MGR=yarn npq-hero"

#### LLM CLI Context Helpers
# Anthropic API key is sourced from 1Password MCP, not exported here for security
export ANTHROPIC_LOG=debug  # Enable debug logging for Claude API calls when needed

# Function to show current Claude Code / LLM context
llm-context() {
  echo "=== Claude Code Context ==="
  echo "Model: ${CLAUDE_CODE_MODEL:-default (Opus)}"
  echo "Working Dir: $(pwd)"
  echo "Shell: $SHELL"
  echo "Git Branch: $(git branch --show-current 2>/dev/null || echo 'not a git repo')"
  echo "Active RTK: $(rtk --version 2>/dev/null || echo 'not installed')"
  echo "Auth Status:"
  echo "  - GitHub: $(gh auth status -h github.com 2>&1 | head -1)"
  echo "  - AWS: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'not authenticated')"
}

# Function to safely log a command for LLM review (strips sensitive patterns)
log-for-llm() {
  local cmd="$1"
  # Remove API keys, tokens, passwords (basic filter)
  echo "$cmd" | sed \
    -e 's/--token[= ][^ ]*/--token ***REDACTED***/g' \
    -e 's/--password[= ][^ ]*/--password ***REDACTED***/g' \
    -e 's/ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=***REDACTED***/g' \
    -e 's/Authorization: Bearer [^ ]*/Authorization: Bearer ***REDACTED***/g'
}

autoload -U +X bashcompinit && bashcompinit

alias ccusage='ccusage --config ~/.config/claude/ccusage.json'

# private, machine/org-specific overrides (never committed)
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

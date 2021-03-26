# set g prefixed names with their default names
export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"

# ohmyzsh init
export ZSH=~/.oh-my-zsh

ZSH_THEME="robbyrussell"

plugins=(
  git
  alias-tips
  node
  npm
  #brew
  osx
  extract
  z
  zsh-256color
  zsh-autosuggestions 
  #zsh-terraform
)

source $ZSH/oh-my-zsh.sh

# grab other aliases
#source ~/.my.aliases
export PATH="/usr/local/sbin:$PATH"
export HOMEBREW_CASK_OPTS="--appdir=~/Applications"

# go stuff
export GOPATH=~/go
export PATH="$GOPATH/bin:$PATH"

# direnv
eval "$(direnv hook zsh)"

# pyenv
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# nvm
export NVM_DIR=~/.nvm
source $(brew --prefix nvm)/nvm.sh

# ???
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit

# random aliases
## misc
alias ls="ls -F --color=auto"
## terraform
alias tf="terraform"
alias tfi="tf init"
alias tfiu="tfi -upgrade"
alias tfriu="rm -rf .terraform && tfiu"
alias tfp="tf plan"
alias tfa="tf apply"
alias tfw="tf workspace"
alias tfwl="tfw list"
alias tfws="tfw select"
alias tfwss="tfws staging"
alias tfwsp="tfws production"
## ripgrep
alias rg="rg --hidden"

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

# terraform cache
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"

# https://github.com/bash-my-aws/bash-my-aws
export PATH="$PATH:$HOME/.bash-my-aws/bin"
source ~/.bash-my-aws/aliases

# For ZSH users, uncomment the following two lines:
autoload -U +X compinit && compinit
autoload -U +X bashcompinit && bashcompinit

export RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@1.1)"

# additional aws aliases and functions
export PATH="/usr/local/opt/libressl/bin:$PATH"

# complete -o nospace -C /usr/local/Cellar/tfenv/2.0.0/versions/0.12.29/terraform terraform

test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"

export PATH="/usr/local/opt/mysql-client/bin:$PATH"

###### global .zshrc

#### source .zshrc_omz
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

# use zplug to manage addons
source ~/.zplug/init.zsh

# stop zsh update prompt, just update
export DISABLE_UPDATE_PROMPT="true"

# For ZSH users, uncomment the following two lines:
# why ?
autoload -U +X compinit && compinit
autoload -U +X bashcompinit && bashcompinit

# ???
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit

#### source .rc_android
# http://gianlucacosta.info/android-studio-ubuntu
export ANDROID_EMULATOR_USE_SYSTEM_LIBS=1
export PATH="/home/user/Android/Sdk/platform-tools:$PATH"
export PATH="/home/user/Android/Sdk/tools/bin:$PATH"

#### source .rc_linux
export SNAP=/snap/
export PATH="/snap/bin/:$PATH"

# linux clipboard specific
alias setclip="xclip -selection c"
alias getclip="xclip -selection c -o"
alias pbcopy=getclip
alias pbpaste=setclip

#### source .rc_osx
# set g prefixed names with their default names
export PATH="/usr/local/opt/coreutils/libexec/gnubin:$PATH"
export PATH="/usr/local/sbin:$PATH"
export HOMEBREW_CASK_OPTS="--appdir=~/Applications"
export HOMEBREW_NO_ANALYTICS=1
export RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@1.1)"
# iterm2 completion
test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"

#### source .rc_code
# go stuff
export GOPATH=~/go
export PATH="$GOPATH/bin:$PATH"

# pyenv
eval "$(pyenv init -)"
# https://github.com/pyenv/pyenv-virtualenv
#eval "$(pyenv virtualenv-init -)"

# nvm
export NVM_DIR=~/.nvm
source $(brew --prefix nvm)/nvm.sh

# direnv
eval "$(direnv hook zsh)"

#### source .rc_misc
## misc alias
alias vi="vim"
alias ls="ls -F --color=auto"
## ripgrep
alias rg="rg --hidden"

#### source .rc_terraform
# terraform cache
# export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
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

# get ssl cert expiration information
# sslcheck google.com
function sslcheck {
  openssl s_client -servername $1 -connect $1:443 | openssl x509 -noout -dates
}

#### source .rc_bma
# https://github.com/bash-my-aws/bash-my-aws
export PATH="$PATH:$HOME/.bash-my-aws/bin"
source ~/.bash-my-aws/aliases
source ~/.aliases_common

# additional aws aliases and functions
#export PATH="/usr/local/opt/libressl/bin:$PATH"
#export PATH="/usr/local/opt/mysql-client/bin:$PATH"

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
  brew
  osx
  extract
  z
  zsh-autosuggestions 
  zsh-256color
)

source $ZSH/oh-my-zsh.sh

# grab other aliases
source ~/.my.aliases

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

# brew doctor says to do this
export PATH="/usr/local/sbin:$PATH"
# maintains my cask apps in my local Applications instead of global
export HOMEBREW_CASK_OPTS="--appdir=~/Applications"
# hook for direnv to auto load .env files
eval "$(direnv hook zsh)"

# grab other aliases
source ~/.my.aliases

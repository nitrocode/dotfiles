# install brew
ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
# download Brewfile
curl -s https://raw.githubusercontent.com/nitrocode/dotfiles/master/macos/Brewfile > Brewfile
# disable analytics
brew analytics off
# install from Brewfile
brew bundle install
# relink anything broken
brew link
# lastly, run the doctor to see anything out of whack
brew doctor

HOMEBREW_DIR=/usr/local/bin
LOCAL_BIN_DIR=/usr/local/bin

# use the gnu tools instead of outdated mac tools
# ls -la /usr/local/bin/g* | \
#   grep coreutils | \
#   cut -d'>' -f1 | \
#   rev | \
#   cut -d' ' -f2 | \
#   rev | \
#   while read gbin; do \
#     ln -s "$gbin" "$(echo $gbin | sed 's,/usr/local/bin/g,/usr/local/bin/,g')"; \
#   done
ln -s $HOMEBREW_DIR/gmake $LOCAL_BIN_DIR/make
## unnecessary?: ln -s /usr/local/bin/gawk /usr/local/bin/awk
ln -s $HOMEBREW_DIR/gsed $LOCAL_BIN_DIR/sed
ln -s $HOMEBREW_DIR/gtar $LOCAL_BIN_DIR/tar
ln -s $HOMEBREW_DIR/ggrep $LOCAL_BIN_DIR/grep
ln -s $HOMEBREW_DIR/gls $LOCAL_BIN_DIR/ls

# use brew less
# source: https://apple.stackexchange.com/a/281116/282367
hash -d less
hash -r

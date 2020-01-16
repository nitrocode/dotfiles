# download Brewfile
ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
# install from Brewfile
brew bundle install
# relink anything broken
brew link
# lastly, run the doctor to see anything out of whack
brew doctor

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
ln -s /usr/local/bin/gmake /usr/local/bin/make
## unnecessary?: ln -s /usr/local/bin/gawk /usr/local/bin/awk
ln -s /usr/local/bin/gsed /usr/local/bin/sed
ln -s /usr/local/bin/gtar /usr/local/bin/tar
ln -s /usr/local/bin/ggrep /usr/local/bin/grep

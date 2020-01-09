# download Brewfile
ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
# install from Brewfile
brew bundle install
# relink anything broken
brew link
# lastly, run the doctor to see anything out of whack
brew doctor

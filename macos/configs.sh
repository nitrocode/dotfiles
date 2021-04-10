#!/bin/sh
# more located at https://github.com/herrbischoff/awesome-macos-command-line

# show osx hidden files by default
defaults write com.apple.finder AppleShowAllFiles NO

# Avoids creation of .DS_Store and AppleDouble files.
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

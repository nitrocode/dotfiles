#!/bin/sh

# first install xcode which is a dependency of gcc which is a dependency of xcrun which is a dependency of tfenv...
xcode-select --install

./brew.sh
./configs.sh
#./dock.sh
./shell.sh

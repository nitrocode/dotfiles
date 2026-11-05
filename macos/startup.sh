#!/usr/bin/env sh

apps=( "KeepingYouAwake.app" "Flux.app" "Google Chrome.app" "Spectacle.app" "Übersicht.app" "Itsycal.app" "Slack.app" )

for i in "${apps[@]}"
do
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"~/Applications/$i\", hidden:true}"
done

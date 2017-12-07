apps=( "Flux.app" "Google Chrome.app" "Spectacle.app" "Microsoft Teams.app" "Übersicht.app" "Google Drive.app" "Itsycal.app" "Slack.app" )

for i in "${apps[@]}"
do
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/$i\", hidden:true}"
done

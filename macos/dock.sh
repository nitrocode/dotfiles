apps=( "Authy Desktop.app" "Firefox.app" "GIMP.app" "Google Chrome.app" "Microsoft Outlook.app" "MySQLWorkbench.app" "SQLWorkbenchJ.app" "Slack.app" "SourceTree.app" "iTerm.app" )

for i in "${apps[@]}"
do
  defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>~/Applications/$i</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
done

# refresh the dock
killall Dock

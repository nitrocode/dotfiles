apps=( "Atom.app" "Authy Desktop.app" "Firefox.app" "GIMP.app" "Goofy.app" "Google Chrome.app" "Google Drive.app" "IntelliJ IDEA CE.app" "Microsoft Outlook.app" "MySQLWorkbench.app" "SQLWorkbenchJ.app" "Skype for Business.app" "Slack.app" "SourceTree.app" "Vagrant Manager.app" "VirtualBox.app" "Xcode.app" "iTerm.app" )

for i in "${apps[@]}"
do
  defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/$i</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
done

# refresh the dock
killall Dock

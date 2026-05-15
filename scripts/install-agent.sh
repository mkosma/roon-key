  cp ~/dev/roontrol/launchd/com.roontrol.plist ~/Library/LaunchAgents/
  launchctl unload ~/Library/LaunchAgents/com.roontrol.plist 2>/dev/null
  launchctl load ~/Library/LaunchAgents/com.roontrol.plist

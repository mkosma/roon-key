  cp ~/dev/roon-key/launchd/com.roon-key.plist ~/Library/LaunchAgents/
  launchctl unload ~/Library/LaunchAgents/com.roon-key.plist 2>/dev/null
  launchctl load ~/Library/LaunchAgents/com.roon-key.plist

import AppKit

// Entry point: hand off to NSApplication with our AppDelegate.
// LSUIElement = true in Info.plist suppresses the dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

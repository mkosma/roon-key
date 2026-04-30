import AppKit

// Swift 6 SPM executable entry point for a menubar app.
// Top-level code in main.swift runs in a nonisolated context.
// We use dispatchMain() to keep the process alive and bootstrap
// the AppKit run loop on the main thread.
//
// The actual startup happens in AppDelegate.applicationDidFinishLaunching.

let app = NSApplication.shared
let delegateRef = AppDelegateRef()
app.delegate = delegateRef
app.run()

/// Bridges nonisolated top-level scope to the @MainActor AppDelegate.
/// This is a lightweight NSObject that NSApplication can retain as its delegate.
final class AppDelegateRef: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var _inner: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let delegate = AppDelegate()
            self._inner = delegate
            delegate.applicationDidFinishLaunching(notification)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            _inner?.applicationWillTerminate(notification)
        }
    }
}

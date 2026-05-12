# roon-key

macOS menubar app that routes media keys and F13-F19 function keys to Roon via [roon-bridge](https://github.com/mkosma/roon-bridge).

## Architecture

```
[Magic Keyboard]
      |
      v
[roon-key: CGEventTap (mbp)]
      |
      | URLSession HTTP POST
      v
[roon-bridge on mini :3100/control/...]
      |
      v
[Roon Core]
```

The mbp talks only to roon-bridge over HTTP. No direct Roon connection from mbp. No Karabiner. No local daemon. Volume ramping is server-side in roon-bridge.

## Key bindings

| Key | Modifier | Action |
|---|---|---|
| Volume Up | none | Smooth ramp up |
| Volume Up | Ctrl | Instant step up |
| Volume Up | Shift | Pass to system |
| Volume Down | none | Smooth ramp down |
| Volume Down | Ctrl | Instant step down |
| Mute | none | Toggle mute |
| Play/Pause | none | Play/pause toggle |
| Next | none | Next track |
| Prev | none | Previous track |
| F13 | none | Preset 1 (default: 32) |
| F14 | none | Preset 2 (default: 40) |
| ... | ... | ... |
| F19 | none | Preset 7 (default: 80) |
| F13-F19 | Ctrl | Jump to preset (instant) |
| F13-F19 | Shift | Pass to system |

At-home detection: interception is active only when on the home LAN (ethernet or wifi, not VPN). When away via WireGuard, all keys pass through to system.

## Requirements

- macOS 13+, Apple Silicon (arm64)
- [roon-bridge](https://github.com/mkosma/roon-bridge) running on mini

## Build

### Option A: Xcode (recommended for mbp)

Open `roon-key.xcodeproj` (once Xcode project is generated). Build and run.

Alternatively: File > Add Package Dependencies, add this repo, build the `roon-key` executable target.

### Option B: Swift Package Manager + make-app.sh

SPM alone produces a bare executable, which cannot be granted Accessibility
permission and does not behave correctly under `LSUIElement`. Use the wrapper
script to build a real `.app`:

```
scripts/make-app.sh                # release build, installs to /Applications
scripts/make-app.sh --debug        # debug build, installs to /Applications
scripts/make-app.sh --run          # also launch after install
```

The script runs `swift build -c release`, assembles `Contents/{MacOS,Info.plist}`,
injects `CFBundleExecutable` and `CFBundlePackageType`, codesigns, and copies
the result to `/Applications/roon-key.app`. See `scripts/README-signing.md`
to make the Accessibility grant persist across rebuilds.

### Note: mini cannot build this

The mini only has Command Line Tools (no Xcode), and AppKit targets require Xcode.
Build on mbp (Xcode installed), then copy the `.app` back.

## Install (v1 -- unsigned)

1. Build the `.app` on mbp.
2. First launch: right-click the `.app` > Open. macOS will ask to confirm opening an unnotarized app.
3. Grant Accessibility permission when prompted: System Settings > Privacy & Security > Accessibility.
4. The menubar icon appears. roon-bridge is discovered automatically via mDNS.

## Configuration

Settings are stored in roon-bridge's `config.json` on the mini under the `roon_key` key.
The Settings popover (click the menubar icon) reads and writes via HTTP to roon-bridge.

Default config:
```json
{
  "roon_key": {
    "active_zone_display_name": "WiiM + 1",
    "volume_step": 8,
    "ramp_step_ms": 20,
    "presets": [32, 40, 48, 56, 64, 72, 80],
    "extras": {
      "open_roon_app": true,
      "muse_toggle": false,
      "favorites": []
    }
  }
}
```

## Karabiner note

If you previously used Karabiner for roon media key routing, the Karabiner rules at
`~/.config/karabiner/assets/complex_modifications/roon-media-keys.json` are no longer
needed. You can remove that file and the corresponding rule in Karabiner-Elements.
roon-key replaces that approach entirely.

## Future work

- Apple Developer signing + notarization (v2)
- App Store distribution
- Full MUSE settings integration
- Smart playlist / favorites browse
- Now Playing notification center widget
- Notch escape / occlusion handling. On notched MacBooks (mbp 14"/16"), once
  enough menubar items pile up to the left of the clock, the notch can hide
  Rondo's status item entirely. macOS does not wrap to the left of the notch
  by default; items past the notch are simply occluded. Options to explore:
  (a) a global keystroke that opens the popover programmatically without
  needing to click the status item; (b) detect occlusion and surface a
  fallback (panel anchored to the screen edge, or a transient HUD).
  Reference: https://tailscale.com/blog/macos-notch-escape — they observe
  occlusion via `NSWindow.didChangeOcclusionStateNotification` on the
  status item button's window:

  ```swift
  self.visibilityObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: statusItemButton.window,
      queue: .main
  ) { [weak self] _ in
      guard let self, statusItem.isVisible else { return }
      isIconOccluded = statusItem.button?.window?.occlusionState.contains(.visible) == false
  }
  ```

  Low priority since Rondo is only useful at home today.

## License

MIT. See [LICENSE](LICENSE).

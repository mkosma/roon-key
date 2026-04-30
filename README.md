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

### Option B: Swift Package Manager (no Xcode)

```
swift build -c release
```

The binary will be at `.build/release/roon-key`. To run as a proper menubar app,
wrap it in an `.app` bundle (see `scripts/make-app.sh` once written).

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

## License

MIT. See [LICENSE](LICENSE).

# roon-key Claude instructions

## What this is

Swift menubar app (mbp) that intercepts media keys and F13-F19 and routes them
to roon-bridge over HTTP. arm64, macOS 13+, no dock icon (LSUIElement).

## Key constraints

- **No Karabiner.** Key interception is CGEventTap only.
- **mbp talks ONLY to roon-bridge via HTTP.** No direct Roon Core connection.
- **No local config on mbp.** All settings live in roon-bridge's config.json.
- **No em dashes** in any output (code comments, commit messages, docs).
- **Server-side ramping.** roon-key sends one HTTP request per keypress.

## Build

On mbp with Xcode: `xcodebuild` or `swift build -c release`.
Mini has CLT only (no Xcode) -- cannot build AppKit targets here.

## Test

```
swift test
```

Tests live in `Tests/roon-keyTests/`. No real Roon calls; MockURLProtocol intercepts URLSession.

## Commit conventions

- `feat:` new feature
- `fix:` bug fix
- `test:` test additions
- `chore:` deps, build, CI
- `docs:` README, comments

## Source layout

```
Sources/roon-key/
  main.swift             -- entry point
  AppDelegate.swift      -- lifecycle, accessibility check
  KeyEventMonitor.swift  -- CGEventTap for consumer keys + F13-F19
  KeyRouter.swift        -- routing decisions (modifier logic, keycode mapping)
  RoonBridgeClient.swift -- URLSession HTTP client + Codable types
  BridgeDiscovery.swift  -- mDNS browser + fallback
  NetworkProfile.swift   -- at-home detection (NWPathMonitor)
  MenubarController.swift -- NSStatusItem + SwiftUI popover

Tests/roon-keyTests/
  NetworkProfileTests.swift   -- interface simulation
  KeyRouterTests.swift        -- keycode mapping, modifier routing
  RoonBridgeClientTests.swift -- encoding, error handling, MockURLProtocol
```

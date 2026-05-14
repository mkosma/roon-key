import AppKit
import SwiftUI

/// MenubarController: NSStatusItem + SwiftUI popover for roon-key.
///
/// Shows: zone name, volume level, connection state dot.
/// Popover: Roon-styled now-playing, transport, volume, presets, footer.
@MainActor
public class MenubarController: NSObject {

    private let bridgeClient: RoonBridgeClient
    private let networkProfile: NetworkProfile

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var statusModel = StatusModel()

    public init(bridgeClient: RoonBridgeClient, networkProfile: NetworkProfile) {
        self.bridgeClient = bridgeClient
        self.networkProfile = networkProfile
    }

    /// Draw the source icon on top of an opaque white circle so it reads on
    /// dark / light desktops alike. The icon's transparent area would otherwise
    /// blend into the wallpaper and look muddy.
    static func compositeOnWhiteDisc(_ src: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let inset = size * 0.12
        let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
        src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    public func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        if let url = Bundle.module.url(forResource: "MenubarIcon", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            let composited = Self.compositeOnWhiteDisc(logo, size: 18)
            composited.isTemplate = false
            item.button?.image = composited
        }
        self.statusItem = item

        networkProfile.onStatusChange = { [weak self] isAtHome in
            self?.updateTitle(isAtHome: isAtHome)
        }

        startPolling()
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
            refreshNow()
        }
    }

    private func showContextMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit roon-key",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc fileprivate func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if let popover = self.popover, popover.isShown {
            popover.performClose(sender)
        } else {
            let pop = NSPopover()
            pop.behavior = .transient
            let host = NSHostingController(
                rootView: SettingsView(
                    model: statusModel,
                    bridgeClient: bridgeClient
                )
            )
            // Lock the popover to a fixed size. Letting NSHostingController
            // propagate preferredContentSize made NSPopover re-anchor on every
            // poll tick, visibly jittering the popover left/right as the
            // volume number changed. SettingsView's outer .frame matches.
            let size = NSSize(width: 380, height: PopoverLayout.height)
            host.view.setFrameSize(size)
            pop.contentSize = size
            pop.contentViewController = host
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover = pop
        }
    }

    // -------------------------------------------------------------------------
    // Title / status dot
    // -------------------------------------------------------------------------

    private func updateTitle(isAtHome: Bool) {
        guard let button = statusItem?.button else { return }

        let indicatorColor: NSColor
        if !isAtHome {
            indicatorColor = NSColor.tertiaryLabelColor
        } else if !statusModel.roonConnected {
            // Bridge reachable but Roon Core not connected to bridge.
            indicatorColor = NSColor.systemYellow
        } else if statusModel.lastStatusError {
            // Bridge unreachable.
            indicatorColor = NSColor.systemRed
        } else {
            indicatorColor = NSColor.systemGreen
        }

        let glyph = statusModel.zoneState == "playing" ? "\u{25B6}" : "\u{23F8}"
        // Right-align volume in a 3-char field with a monospaced-digit font
        // so the menubar button width stays constant as volume changes.
        // Otherwise the variable-length status item resizes and the popover
        // (anchored to the button) shifts left/right with every poll tick.
        let volume = statusModel.volume.map { String(format: "%3d", $0) } ?? " --"
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(
            string: " \(volume)  ",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: monoFont,
            ]
        ))
        attr.append(NSAttributedString(
            string: glyph,
            attributes: [
                .foregroundColor: indicatorColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ]
        ))
        button.attributedTitle = attr
    }

    // -------------------------------------------------------------------------
    // Polling
    // -------------------------------------------------------------------------

    private var fastPollUntil: Date = .distantPast

    private func startPolling() {
        // Refresh immediately whenever a control action fires (keypress
        // or popover button) so the displayed volume / state catches up.
        NotificationCenter.default.addObserver(
            forName: .roonKeyDidAct,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // During a ramp the volume keeps changing for ~1-2s. Bump the
        // poll cadence so the menubar number tracks the ramp.
        NotificationCenter.default.addObserver(
            forName: .roonKeyDidRamp,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fastPollUntil = Date().addingTimeInterval(2.5)
                self?.refreshNow()
            }
        }

        Task {
            while !Task.isCancelled {
                await pollOnce()
                let interval: Duration = Date() < fastPollUntil
                    ? .milliseconds(33)
                    : .seconds(1)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refreshNow() {
        Task { await pollOnce() }
    }

    private func pollOnce() async {
        do {
            let s = try await bridgeClient.status()
            statusModel.lastStatusError = false
            statusModel.roonConnected = s.roonConnected
            statusModel.zoneName = s.zone?.displayName
            statusModel.volume = s.zone?.volume
            statusModel.muted = s.zone?.muted ?? false
            statusModel.zones = s.zones ?? []
            statusModel.nowPlayingTitle = s.zone?.nowPlayingTitle
            statusModel.nowPlayingArtist = s.zone?.nowPlayingArtist
            statusModel.nowPlayingAlbum = s.zone?.nowPlayingAlbum
            let activeName = s.zone?.displayName
            statusModel.zoneState = s.zone?.state
                ?? (s.zones ?? []).first { $0.displayName == activeName }?.state
            if let cfg = s.config {
                statusModel.config = cfg
            }
            updateTitle(isAtHome: networkProfile.isAtHome)
        } catch {
            statusModel.lastStatusError = true
            statusModel.roonConnected = false
            updateTitle(isAtHome: networkProfile.isAtHome)
        }
    }
}

// -------------------------------------------------------------------------
// Cross-component refresh signals
// -------------------------------------------------------------------------

extension Notification.Name {
    /// Posted whenever a control action completes (keypress or in-popover
    /// button). Triggers an immediate menubar status refresh.
    static let roonKeyDidAct = Notification.Name("roonKeyDidAct")
    /// Posted when a ramping action is initiated. Triggers burst polling.
    static let roonKeyDidRamp = Notification.Name("roonKeyDidRamp")
}

// -------------------------------------------------------------------------
// Status model
// -------------------------------------------------------------------------

@MainActor
public class StatusModel: ObservableObject {
    @Published var roonConnected = false
    @Published var zoneName: String? = nil
    @Published var volume: Int? = nil
    @Published var muted = false
    @Published var zones: [ZoneSummary] = []
    @Published var config = RoonKeyConfig()
    @Published var isSavingConfig = false
    @Published var nowPlayingTitle: String? = nil
    @Published var nowPlayingArtist: String? = nil
    @Published var nowPlayingAlbum: String? = nil
    @Published var zoneState: String? = nil
    @Published var lastStatusError: Bool = false
}

// -------------------------------------------------------------------------
// Popover layout constants
// -------------------------------------------------------------------------

enum PopoverLayout {
    static let width: CGFloat = 380
    /// Hard-coded so the popover never resizes -- prevents NSPopover from
    /// re-anchoring (and visibly jittering) as data inside changes.
    static let height: CGFloat = 470
}

// -------------------------------------------------------------------------
// Roon style tokens
// -------------------------------------------------------------------------

private enum RoonStyle {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let bgElevated = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let accent = Color(red: 0.36, green: 0.31, blue: 0.91)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let hairline = Color.white.opacity(0.08)
    static let okDot = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warnDot = Color(red: 0.95, green: 0.78, blue: 0.30)

    // Roon ships these fonts inside the desktop app; we bundle the same files.
    // Display = Grifo (transitional serif). Body / UI = Lato (humanist sans).
    static func display(_ size: CGFloat) -> Font {
        Font.custom("GrifoS-Medium", size: size)
    }
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Lato-Bold"
        case .semibold, .medium: name = "Lato-Medium"
        default: name = "Lato-Regular"
        }
        return Font.custom(name, size: size)
    }
}

// -------------------------------------------------------------------------
// Settings popover (main view)
// -------------------------------------------------------------------------

struct SettingsView: View {
    @ObservedObject var model: StatusModel
    let bridgeClient: RoonBridgeClient

    @State private var showAbout = false
    @State private var showEdit = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(RoonStyle.hairline)
            nowPlaying
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Divider().background(RoonStyle.hairline)
            transportRow
                .padding(.vertical, 18)
            Divider().background(RoonStyle.hairline)
            volumeRow
                .padding(.vertical, 16)
            Divider().background(RoonStyle.hairline)
            presetRow
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider().background(RoonStyle.hairline)
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .frame(width: PopoverLayout.width, height: PopoverLayout.height)
        // Disable implicit SwiftUI animations on data-driven text so we don't
        // animate intrinsic widths between poll ticks. Combined with the
        // fixed popover size in togglePopover, this keeps the popover from
        // re-anchoring as data changes.
        .transaction { $0.animation = nil }
        .background(RoonStyle.bg)
        .preferredColorScheme(.dark)
        .background(
            // Hidden buttons for keyboard shortcuts.
            ZStack {
                Button("") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
                Button("") { showEdit = true }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") { showAbout = true }
                    .keyboardShortcut("i", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        )
        .sheet(isPresented: $showAbout) {
            AboutSheet(onClose: { showAbout = false })
        }
        .sheet(isPresented: $showEdit) {
            EditSheet(
                model: model,
                bridgeClient: bridgeClient,
                onClose: { showEdit = false }
            )
        }
    }

    // ---- Toolbar ----

    private var toolbar: some View {
        HStack(spacing: 14) {
            Text("RoonTrol")
                .font(RoonStyle.display(20))
                .foregroundColor(RoonStyle.textPrimary)
                .tracking(0.5)
            Spacer()
            toolbarIcon("info.circle") { showAbout.toggle() }
            toolbarIcon("gearshape") { showEdit.toggle() }
            toolbarIcon("power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toolbarIcon(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(RoonStyle.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ---- Now playing ----

    private var nowPlaying: some View {
        let state = model.zoneState ?? ""
        let title = model.nowPlayingTitle ?? ""
        let artist = model.nowPlayingArtist ?? ""
        let displayTitle: String
        let displaySubtitle: String
        let dim: Bool
        if !title.isEmpty {
            displayTitle = title
            displaySubtitle = artist
            dim = false
        } else if state == "playing" {
            displayTitle = "Playing"
            displaySubtitle = model.zoneName ?? ""
            dim = false
        } else if state == "paused" {
            displayTitle = "Paused"
            displaySubtitle = model.zoneName ?? ""
            dim = true
        } else {
            displayTitle = "Not playing"
            displaySubtitle = ""
            dim = true
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(displayTitle)
                .font(RoonStyle.display(20))
                .foregroundColor(dim ? RoonStyle.textTertiary : RoonStyle.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(displaySubtitle.isEmpty ? " " : displaySubtitle)
                .font(RoonStyle.body(13))
                .foregroundColor(RoonStyle.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ---- Transport ----

    private var transportRow: some View {
        let isPlaying = model.zoneState == "playing"
        return HStack(spacing: 36) {
            transportButton(symbol: "backward.fill", size: 18, accent: false) {
                Task { try? await bridgeClient.transport(action: .prev) }
            }
            transportButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 22, accent: true) {
                Task { try? await bridgeClient.transport(action: .playpause) }
            }
            transportButton(symbol: "forward.fill", size: 18, accent: false) {
                Task { try? await bridgeClient.transport(action: .next) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(symbol: String, size: CGFloat, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(accent ? RoonStyle.accent : Color.clear)
                    .overlay(
                        Circle().stroke(accent ? Color.clear : RoonStyle.hairline, lineWidth: 1)
                    )
                    .frame(width: accent ? 56 : 44, height: accent ? 56 : 44)
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .medium))
                    .foregroundColor(accent ? .white : RoonStyle.textPrimary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // ---- Volume ----

    private var volumeRow: some View {
        // Mute hangs off to the left without disturbing the centered cluster.
        // The number lives inside a fixed-size ZStack so the MUTED label
        // (offset below) doesn't push the number off the buttons' midline.
        ZStack {
            HStack(spacing: 22) {
                volIconButton(symbol: "minus") {
                    Task { try? await bridgeClient.volumeInstant(direction: .down, step: 1) }
                }
                ZStack {
                    Text(model.volume.map(String.init) ?? "--")
                        .font(RoonStyle.body(38))
                        .foregroundColor(model.muted ? RoonStyle.textSecondary : RoonStyle.textPrimary)
                        .monospacedDigit()
                        .animation(nil, value: model.volume)
                    Text("MUTED")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(RoonStyle.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(
                            Capsule().stroke(RoonStyle.accent.opacity(0.6), lineWidth: 1)
                        )
                        .opacity(model.muted ? 1 : 0)
                        .offset(y: 30)
                        .allowsHitTesting(false)
                }
                .frame(width: 96, height: 50)
                volIconButton(symbol: "plus") {
                    Task { try? await bridgeClient.volumeInstant(direction: .up, step: 1) }
                }
            }

            HStack {
                volIconButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    Task { try? await bridgeClient.muteToggle() }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }

    private func volIconButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RoonStyle.bgElevated)
                    .overlay(Circle().stroke(RoonStyle.hairline, lineWidth: 1))
                    .frame(width: 36, height: 36)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(RoonStyle.textPrimary)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // ---- Presets ----

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.config.presets.enumerated()), id: \.offset) { idx, value in
                VStack(spacing: 4) {
                    presetPill(value: value, active: model.volume == value) {
                        Task { try? await bridgeClient.volumePreset(index: idx + 1, instant: false) }
                    }
                    Text("F\(13 + idx)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(RoonStyle.textTertiary)
                }
            }
        }
    }

    private func presetPill(value: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(value)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundColor(active ? RoonStyle.accent : RoonStyle.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(
                    Capsule().stroke(
                        active ? RoonStyle.accent : RoonStyle.hairline,
                        lineWidth: active ? 1.5 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    // ---- Footer ----

    private var footer: some View {
        HStack {
            zonePicker
            Spacer()
            statusIndicator
        }
    }

    private var zonePicker: some View {
        Menu {
            ForEach(model.zones) { zone in
                Button(zone.displayName) {
                    model.config.activeZoneDisplayName = zone.displayName
                    Task { try? await bridgeClient.setConfig(model.config) }
                }
            }
            if model.zones.isEmpty {
                Text("No zones available").foregroundColor(RoonStyle.textSecondary)
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.config.activeZoneDisplayName)
                    .font(.system(size: 11))
                    .foregroundColor(RoonStyle.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(RoonStyle.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.roonConnected ? RoonStyle.okDot : RoonStyle.warnDot)
                .frame(width: 8, height: 8)
            Text(model.roonConnected ? "Connected" : "Bridge unreachable")
                .font(.system(size: 11))
                .foregroundColor(RoonStyle.textSecondary)
        }
    }
}

// -------------------------------------------------------------------------
// About sheet
// -------------------------------------------------------------------------

private struct AboutSheet: View {
    let onClose: () -> Void

    private let bindings: [(String, String)] = [
        ("Mute toggle", "fn + F10"),
        ("Volume -1", "fn + F11"),
        ("Volume +1", "fn + F12"),
        ("Volume preset (ramp)", "F13 to F19"),
        ("Volume preset (instant)", "fn + F13 to F19"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RoonTrol")
                    .font(RoonStyle.display(34))
                    .foregroundColor(RoonStyle.textPrimary)
                Text("a menubar remote for Roon")
                    .font(RoonStyle.body(13))
                    .foregroundColor(RoonStyle.textSecondary)
                Text("(c) 2026 Monty Kosma")
                    .font(.system(size: 11))
                    .foregroundColor(RoonStyle.textTertiary)
            }
            .padding(.bottom, 22)

            Text("Keystrokes")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(RoonStyle.textTertiary)
                .padding(.bottom, 10)

            VStack(spacing: 10) {
                ForEach(bindings, id: \.0) { row in
                    HStack {
                        Text(row.0)
                            .font(.system(size: 13))
                            .foregroundColor(RoonStyle.textPrimary)
                        Spacer()
                        Text(row.1)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(RoonStyle.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(RoonStyle.bgElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(RoonStyle.hairline, lineWidth: 1)
                            )
                    }
                }
            }

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380, height: 380)
        .background(RoonStyle.bg)
        .preferredColorScheme(.dark)
    }
}

// -------------------------------------------------------------------------
// Edit sheet
// -------------------------------------------------------------------------

private struct EditSheet: View {
    @ObservedObject var model: StatusModel
    let bridgeClient: RoonBridgeClient
    let onClose: () -> Void

    @State private var presetEdits: [Int] = []
    @State private var evenMin: Int = 32
    @State private var evenMax: Int = 80
    @State private var rampSecondsPerUnit: Double = 0.020
    @State private var errorText: String = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Presets & Ramp")
                .font(RoonStyle.display(20))
                .foregroundColor(RoonStyle.textPrimary)

            // Presets row
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Volume presets")
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { presetEdits.indices.contains(i) ? presetEdits[i] : 0 },
                                set: { newVal in
                                    ensureSize()
                                    presetEdits[i] = max(0, min(100, newVal))
                                }
                            ), format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(RoonStyle.textPrimary)
                            .frame(width: 44, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(RoonStyle.bgElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RoonStyle.hairline, lineWidth: 1)
                            )
                            Text("F\(13 + i)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(RoonStyle.textTertiary)
                        }
                    }
                }
            }

            // Even distribution
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Even distribution")
                HStack(spacing: 10) {
                    Spacer()
                    numField(label: "Min", value: $evenMin)
                    numField(label: "Max", value: $evenMax)
                    Button("Apply", action: applyEvenSpacing)
                        .controlSize(.small)
                }
            }

            // Ramp speed
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Ramp speed")
                HStack(spacing: 12) {
                    Slider(value: $rampSecondsPerUnit, in: 0.005...0.5, step: 0.005)
                    TextField("", value: $rampSecondsPerUnit, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(RoonStyle.textPrimary)
                        .frame(width: 60, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(RoonStyle.bgElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(RoonStyle.hairline, lineWidth: 1)
                        )
                }
                Text("Time to change volume by 1 unit.")
                    .font(.system(size: 10))
                    .foregroundColor(RoonStyle.textTertiary)
            }

            Spacer(minLength: 4)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(0.85))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420)
        .background(RoonStyle.bg)
        .preferredColorScheme(.dark)
        .onAppear(perform: loadFromModel)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundColor(RoonStyle.textTertiary)
    }

    private func numField(label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(RoonStyle.textSecondary)
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .foregroundColor(RoonStyle.textPrimary)
                .frame(width: 48, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(RoonStyle.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(RoonStyle.hairline, lineWidth: 1)
                )
        }
    }

    private func ensureSize() {
        while presetEdits.count < 7 { presetEdits.append(0) }
        if presetEdits.count > 7 { presetEdits = Array(presetEdits.prefix(7)) }
    }

    private func loadFromModel() {
        var p = model.config.presets
        while p.count < 7 { p.append(0) }
        presetEdits = Array(p.prefix(7))
        if let lo = presetEdits.first { evenMin = lo }
        if let hi = presetEdits.last { evenMax = hi }
        rampSecondsPerUnit = max(0.005, min(0.5, Double(model.config.rampStepMs) / 1000.0))
    }

    private func applyEvenSpacing() {
        let lo = max(0, min(100, evenMin))
        let hi = max(0, min(100, evenMax))
        guard hi >= lo else { return }
        let span = Double(hi - lo)
        var result: [Int] = []
        for i in 0..<7 {
            let t = Double(i) / 6.0
            result.append(Int((Double(lo) + t * span).rounded()))
        }
        presetEdits = result
    }

    private func save() {
        ensureSize()
        let clamped = presetEdits.map { max(0, min(100, $0)) }
        model.config.presets = clamped
        model.config.rampStepMs = max(1, Int((rampSecondsPerUnit * 1000.0).rounded()))
        isSaving = true
        errorText = ""
        Task {
            do {
                try await bridgeClient.setConfig(model.config)
                isSaving = false
                onClose()
            } catch {
                isSaving = false
                errorText = "Save failed: \(error.localizedDescription)"
            }
        }
    }
}

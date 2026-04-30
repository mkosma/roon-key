import AppKit
import SwiftUI

/// MenubarController: NSStatusItem + SwiftUI popover for roon-key.
///
/// Shows: zone name, volume level, connection state dot.
/// Popover: zone picker, volume step, ramp ms, presets editor, Open Roon button, status.
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

    public func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "roon"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        self.statusItem = item

        networkProfile.onStatusChange = { [weak self] isAtHome in
            self?.updateTitle(isAtHome: isAtHome)
        }

        // Start polling bridge status every 5 seconds
        startPolling()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if let popover = self.popover, popover.isShown {
            popover.performClose(sender)
        } else {
            let pop = NSPopover()
            pop.contentSize = NSSize(width: 320, height: 460)
            pop.behavior = .transient
            pop.contentViewController = NSHostingController(
                rootView: SettingsView(
                    model: statusModel,
                    bridgeClient: bridgeClient
                )
            )
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover = pop
        }
    }

    // -------------------------------------------------------------------------
    // Title / status dot
    // -------------------------------------------------------------------------

    private func updateTitle(isAtHome: Bool) {
        guard let button = statusItem?.button else { return }

        let dot: String
        if !isAtHome {
            dot = "⚫" // away
        } else if statusModel.roonConnected {
            dot = "🟢" // home + connected
        } else {
            dot = "🟡" // home, bridge unreachable
        }

        let volume = statusModel.volume.map { "\($0)" } ?? "--"
        let zone = statusModel.zoneName ?? "roon"
        button.title = "\(dot) \(zone) \(volume)"
    }

    // -------------------------------------------------------------------------
    // Polling
    // -------------------------------------------------------------------------

    private func startPolling() {
        Task {
            while true {
                do {
                    let s = try await bridgeClient.status()
                    statusModel.roonConnected = s.roonConnected
                    statusModel.zoneName = s.zone?.displayName
                    statusModel.volume = s.zone?.volume
                    statusModel.muted = s.zone?.muted ?? false
                    statusModel.zones = s.zones ?? []
                    if let cfg = s.config {
                        statusModel.config = cfg
                    }
                    updateTitle(isAtHome: networkProfile.isAtHome)
                } catch {
                    statusModel.roonConnected = false
                    updateTitle(isAtHome: networkProfile.isAtHome)
                }

                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// -------------------------------------------------------------------------
// Status model (ObservableObject for SwiftUI binding)
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
}

// -------------------------------------------------------------------------
// Settings popover (SwiftUI)
// -------------------------------------------------------------------------

struct SettingsView: View {
    @ObservedObject var model: StatusModel
    let bridgeClient: RoonBridgeClient

    @State private var editingPresets: String = ""
    @State private var saveStatus: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("roon-key Settings")
                    .font(.headline)
                    .padding(.top, 12)

                Divider()

                // Zone picker
                if !model.zones.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Zone").font(.subheadline).foregroundColor(.secondary)
                        Picker("Zone", selection: Binding(
                            get: { model.config.activeZoneDisplayName },
                            set: { model.config.activeZoneDisplayName = $0 }
                        )) {
                            ForEach(model.zones) { zone in
                                Text(zone.displayName).tag(zone.displayName)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }

                // Volume step slider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume Step: \(model.config.volumeStep)")
                        .font(.subheadline).foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(model.config.volumeStep) },
                            set: { model.config.volumeStep = Int($0) }
                        ),
                        in: 1...50,
                        step: 1
                    )
                }

                // Ramp speed slider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ramp Step: \(model.config.rampStepMs) ms")
                        .font(.subheadline).foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(model.config.rampStepMs) },
                            set: { model.config.rampStepMs = Int($0) }
                        ),
                        in: 5...200,
                        step: 5
                    )
                }

                // Presets
                VStack(alignment: .leading, spacing: 4) {
                    Text("Presets (F13-F\(12 + model.config.presets.count), comma-separated)")
                        .font(.subheadline).foregroundColor(.secondary)
                    TextField("32,40,48,56,64,72,80", text: $editingPresets)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            editingPresets = model.config.presets.map(String.init).joined(separator: ",")
                        }
                        .onChange(of: editingPresets) { _, newVal in
                            let parsed = newVal
                                .split(separator: ",")
                                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                                .filter { (0...100).contains($0) }
                            if !parsed.isEmpty && parsed.count <= 12 {
                                model.config.presets = parsed
                            }
                        }
                }

                // Extras toggles
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open Roon app shortcut (mini)", isOn: Binding(
                        get: { model.config.extras.openRoonApp },
                        set: { model.config.extras.openRoonApp = $0 }
                    ))
                }

                // Open Roon on mini button
                Button("Open Roon on mini") {
                    Task {
                        try? await bridgeClient.openRoonApp()
                    }
                }
                .buttonStyle(.bordered)

                Divider()

                // Save button
                HStack {
                    Button("Save to bridge") {
                        Task {
                            model.isSavingConfig = true
                            do {
                                try await bridgeClient.setConfig(model.config)
                                saveStatus = "Saved."
                            } catch {
                                saveStatus = "Error: \(error.localizedDescription)"
                            }
                            model.isSavingConfig = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSavingConfig)

                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Divider()

                // Status footer
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roon: \(model.roonConnected ? "connected" : "disconnected")")
                        .font(.caption).foregroundColor(.secondary)
                    if let name = model.zoneName {
                        Text("Zone: \(name)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if let vol = model.volume {
                        Text("Volume: \(vol)\(model.muted ? " (muted)" : "")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 16)
        }
    }
}

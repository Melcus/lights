#if DEBUG
import AppKit
import LightsKit
import SwiftUI

/// Debug aid: `Lights -designSnapshots <directory>` renders the panel in a range of states, in
/// light and dark appearance, then quits. The glass is approximated by a flat platter.
enum DesignSnapshots {
    static func renderIfRequested() -> Bool {
        guard let directory = UserDefaults.standard.string(forKey: "designSnapshots") else { return false }
        for scheme in [ColorScheme.light, .dark] {
            let sheet = HStack(alignment: .top, spacing: 24) {
                ForEach(Array(samples().enumerated()), id: \.offset) { index, store in
                    PanelView(openSettings: { _ in })
                        .environment(store)
                        .environment(adaptive(for: store, enabled: index < 2))
                        .environment(presets(for: store))
                        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(platter(for: scheme)))
                }
            }
            .padding(24)
            .background(backdrop(for: scheme))
            .environment(\.colorScheme, scheme)
            write(sheet, to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(scheme == .dark ? "dark" : "light").png"))
        }
        return true
    }

    /// The panel as it is now, with the real lights, rendered off screen.
    static func renderLive(store: LightStore, adaptive: AdaptiveLighting, presets: PresetStore, to directory: String) {
        for scheme in [ColorScheme.light, .dark] {
            let panel = PanelView(openSettings: { _ in })
                .environment(store)
                .environment(adaptive)
                .environment(presets)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(platter(for: scheme)))
                .padding(24)
                .background(backdrop(for: scheme))
                .environment(\.colorScheme, scheme)
            write(panel, to: URL(fileURLWithPath: directory).appendingPathComponent("live-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func samples() -> [LightStore] {
        let allOn = store(
            keyLight(isOn: true, brightness: 30, kelvin: 7000),
            lyra(isOn: true, brightness: 27, color: .white(kelvin: 4800)),
            magrgb(isOn: true, color: .effect("Northern Lights"))
        )
        let mixed = store(
            keyLight(isOn: false, brightness: 30, kelvin: 4350),
            lyra(isOn: true, brightness: 80, color: .rgb(RGB(r: 255, g: 60, b: 170))),
            magrgb(isOn: true, color: .white(kelvin: 3200))
        )
        let unpaired = magrgb(isOn: false, color: .unchanged)
        unpaired.availability = .connecting
        unpaired.pairing = .needed
        let trouble = store(lyra(isOn: false, brightness: 27, color: .white(kelvin: 2700)), unpaired)
        trouble.lights.first { $0.kind == .govee }?.availability = .offline
        // Matches the built-in Relax preset, which shows lit.
        let relaxing = store(
            keyLight(isOn: false, brightness: 30, kelvin: 4350),
            lyra(isOn: true, brightness: 35, color: .white(kelvin: 2700)),
            magrgb(isOn: true, brightness: 35, color: .white(kelvin: 2700))
        )
        return [allOn, mixed, relaxing, trouble, LightStore()]
    }

    /// Separate defaults so rendering never touches the real setting.
    private static func adaptive(for store: LightStore, enabled: Bool) -> AdaptiveLighting {
        let defaults = UserDefaults(suiteName: "ro.tirdea.Lights.snapshots")!
        defaults.set(enabled, forKey: "adaptive.enabled")
        return AdaptiveLighting(store: store, defaults: defaults)
    }

    /// The built-in presets, whatever the real ones are.
    private static func presets(for store: LightStore) -> PresetStore {
        let defaults = UserDefaults(suiteName: "ro.tirdea.Lights.snapshots")!
        defaults.removeObject(forKey: "presets")
        return PresetStore(store: store, defaults: defaults)
    }

    private static func store(_ lights: Light...) -> LightStore {
        let store = LightStore()
        lights.forEach(store.add)
        return store
    }

    private static func keyLight(isOn: Bool, brightness: Int, kelvin: Int) -> Light {
        let light = Light(id: "sample-keylight", kind: .keyLight, defaultName: "Key Light Neo", model: "Elgato Key Light Neo",
                          capabilities: .init(brightnessRange: 3...100, kelvinRange: 2900...7000, supportsColor: false))
        light.maxBrightness = 40
        light.applyReported(isOn: isOn, brightness: brightness, color: .white(kelvin: kelvin))
        return light
    }

    private static func lyra(isOn: Bool, brightness: Int, color: Light.ReportedColor) -> Light {
        let light = Light(id: "sample-lyra", kind: .govee, defaultName: "Lyra", model: "Govee H6072",
                          capabilities: GoveeCatalog.capabilities(for: "H6072"))
        light.applyReported(isOn: isOn, brightness: brightness, color: color)
        return light
    }

    private static func magrgb(isOn: Bool, brightness: Int = 64, color: Light.ReportedColor) -> Light {
        let light = Light(id: "sample-magrgb", kind: .nanoleaf, defaultName: "MAGRGB", model: "Secretlab MAGRGB (NL72S2)",
                          capabilities: .init(brightnessRange: 1...100, kelvinRange: 2127...6535, supportsColor: true))
        let scenes: [(String, [String])] = [
            ("Northern Lights", ["0037FF", "00F6FF", "00FF15", "F6FF00", "FF8300", "FF0800", "FF00E1"]),
            ("Assassin's Creed", ["FF0000", "FFF2D8", "FFF3DB"]),
            ("Cyberpunk 2077", ["FFEE32", "19B9E5"]),
            ("Dark Knight", ["FFE359", "000000", "000000", "FFE359"]),
            ("Secret Lab Signature", ["FF0000", "564C66", "C099E5", "957E99"]),
            ("Volume Up", ["FF00DD", "D400FF", "7F00FF", "1D00FF", "008CFF"]),
        ]
        light.effects = scenes.map { Light.Effect(name: $0.0, palette: $0.1.compactMap(RGB.init(hex:)), isRhythm: $0.0 == "Volume Up") }
        light.applyReported(isOn: isOn, brightness: brightness, color: color)
        return light
    }

    private static func platter(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17, opacity: 0.94) : Color(white: 0.95, opacity: 0.94)
    }

    private static func backdrop(for scheme: ColorScheme) -> some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.22, green: 0.13, blue: 0.20)]
                : [Color(red: 0.62, green: 0.72, blue: 0.86), Color(red: 0.86, green: 0.74, blue: 0.70)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}
/// Debug aid: scripts drive the store through the same methods the UI uses by posting a
/// `ro.tirdea.Lights.debug` distributed notification whose object is "<command> [light id] [value]".
/// Commands: toggle, brightness, kelvin, color <id> <r> <g> <b>, scene <id> <name>, pair, forget,
/// dump (writes state to /tmp/lights-state.json), settings <tab index>, close-settings,
/// adaptive on|off, panel (opens or closes it), snapshot <directory> (renders the live panel),
/// auto <light id> (the Auto pill), wedge-govee (breaks the Govee socket to exercise recovery),
/// nanoleaf-token <id> <file> (adopts a token a script obtained, then deletes the file), and for
/// presets: preset <name> (applies it), preset-save <name>, preset-delete <name> and presets
/// (writes them to /tmp/lights-presets.json).
enum DebugCommands {
    static func install(
        store: LightStore, settings: SettingsWindowController, adaptive: AdaptiveLighting, presets: PresetStore,
        togglePanel: @escaping @MainActor @Sendable () -> Void
    ) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ro.tirdea.Lights.debug"), object: nil, queue: .main
        ) { notification in
            guard let command = notification.object as? String else { return }
            MainActor.assumeIsolated {
                if command == "panel" {
                    togglePanel()
                } else if command.hasPrefix("preset") {
                    runPreset(command, store: store, presets: presets)
                } else {
                    run(command, store: store, settings: settings, adaptive: adaptive, presets: presets)
                }
            }
        }
    }

    private static func runPreset(_ command: String, store: LightStore, presets: PresetStore) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.count > 1 ? parts[1] : ""
        let preset = presets.presets.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
        switch parts[0] {
        case "preset": preset.map(presets.apply)
        case "preset-save" where !name.isEmpty: presets.saveCurrentLights(named: name)
        case "preset-delete": preset.map(presets.delete)
        case "presets":
            let state = presets.presets.map { preset in
                ["id": preset.id.uuidString, "name": preset.displayName, "symbol": preset.symbol,
                 "active": presets.isActive(preset), "lights": preset.summary(for: store.lights)] as [String: Any]
            }
            let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: "/tmp/lights-presets.json"))
        default: break
        }
    }

    private static func run(
        _ command: String, store: LightStore, settings: SettingsWindowController, adaptive: AdaptiveLighting, presets: PresetStore
    ) {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "settings":
            settings.show()
            (settings.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            return
        case "close-settings":
            settings.close()
            return
        case "adaptive":
            adaptive.isEnabled = parts.count > 1 && parts[1] == "on"
            return
        case "wedge-govee":
            store.simulateStuckGoveeSocket()
            return
        case "snapshot":
            DesignSnapshots.renderLive(store: store, adaptive: adaptive, presets: presets, to: parts.count > 1 ? parts[1] : "/tmp")
            return
        default:
            break
        }
        if parts.first == "dump" {
            let state = store.lights.map { light in
                [
                    "id": light.id, "name": light.name, "reachable": light.isReachable, "on": light.isOn,
                    "brightness": light.brightness, "kelvin": light.kelvin,
                    "color": light.color.map { "\($0.r),\($0.g),\($0.b)" } ?? "none",
                    "maxBrightness": light.maxBrightness ?? 100, "detail": light.connectionDetail,
                    "scene": light.effect ?? "none", "scenes": light.effects.map(\.name),
                    "pairing": light.pairing.map { "\($0)" } ?? "none", "firmware": light.firmwareVersion ?? "unknown",
                    "kelvinRange": "\(light.capabilities.kelvinRange)", "availability": "\(light.availability)",
                    "adaptive": adaptive.follows(light) ? "following" : adaptive.isEnabled ? "paused" : "off",
                ] as [String: Any]
            }
            let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: "/tmp/lights-state.json"))
            return
        }
        guard parts.count >= 2, let light = store.light(id: parts[1]) else { return }
        let value = parts.count > 2 ? Int(parts[2]) : nil
        switch (parts[0], value) {
        case ("toggle", _): store.toggle(light)
        case ("brightness", let value?): store.setBrightness(value, for: light)
        case ("kelvin", let value?): store.setKelvin(value, for: light)
        case ("auto", _): adaptive.resume(light)
        case ("pair", _): store.pair(light)
        case ("forget", _): store.forget(light)
        case ("scene", _) where parts.count > 2: store.setEffect(parts[2...].joined(separator: " "), for: light)
        case ("color", _) where parts.count == 5:
            if let r = Int(parts[2]), let g = Int(parts[3]), let b = Int(parts[4]) { store.setColor(RGB(r: r, g: g, b: b), for: light) }
        case ("nanoleaf-token", _) where parts.count == 3:
            let url = URL(fileURLWithPath: parts[2])
            guard let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return }
            store.adoptNanoleafToken(token, for: light)
            try? FileManager.default.removeItem(at: url)
        default: break
        }
    }
}

#endif

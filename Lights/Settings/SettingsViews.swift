import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Lights at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, enabled in setOpensAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Menu bar icon") {
                LabeledContent("Click", value: "Show lights")
                LabeledContent("Option-click", value: "Toggle all lights")
                LabeledContent("Right-click", value: "Quick actions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 250)
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct ShortcutsSettingsView: View {
    @Environment(LightStore.self) private var store
    @Environment(ShortcutCenter.self) private var shortcuts

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Toggle all lights", action: .toggleAll)
                ShortcutRow(title: "Turn all lights on", action: .allOn)
                ShortcutRow(title: "Turn all lights off", action: .allOff)
                ShortcutRow(title: "Brighter", subtitle: "+10% on lights that are on", action: .brighter)
                ShortcutRow(title: "Dimmer", subtitle: "−10% on lights that are on", action: .dimmer)
            } header: {
                Text("All lights")
            } footer: {
                Text("Shortcuts work from any app and need ⌃ or ⌥, except function keys. Press Delete while recording to clear one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Individual lights") {
                if store.lights.isEmpty {
                    Text("Lights appear here once they're connected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.lights) { light in
                    ShortcutRow(title: "Toggle \(light.name)", action: .toggle(light.id))
                }
                ForEach(disconnectedLightActions, id: \.self) { action in
                    ShortcutRow(title: "Toggle a disconnected light", subtitle: action.lightID, action: action)
                }
            }
            Section("App") {
                ShortcutRow(title: "Show lights panel", action: .showPanel)
                ShortcutRow(title: "Toggle adaptive lighting", action: .toggleAdaptive)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 630)
    }

    /// Shortcuts stay registered for lights that are unplugged or gone, so keep them clearable.
    private var disconnectedLightActions: [ShortcutAction] {
        shortcuts.shortcuts.keys
            .filter { action in action.lightID.map { store.light(id: $0) == nil } ?? false }
            .sorted { $0.rawValue < $1.rawValue }
    }
}

private struct ShortcutRow: View {
    let title: String
    var subtitle: String?
    let action: ShortcutAction

    var body: some View {
        LabeledContent {
            ShortcutRecorder(action: action)
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}

struct LightsSettingsView: View {
    @Environment(LightStore.self) private var store

    var body: some View {
        Form {
            if store.lights.isEmpty {
                Section {
                    Text("No lights found yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.lights) { light in
                Section {
                    TextField("Name", text: name(for: light), prompt: Text(light.defaultName))
                    LabeledContent("Model", value: light.model)
                    if let firmware = light.firmwareVersion {
                        LabeledContent("Firmware", value: firmware)
                    }
                    LabeledContent("Connection", value: light.connectionDetail)
                    if let cap = light.maxBrightness {
                        LabeledContent("Brightness limit", value: "\(cap)% on this USB power source")
                            .help("Powering the light from a 3 A USB-C supply allows full brightness.")
                    }
                    LabeledContent("Status", value: status(of: light))
                    if light.kind == .govee {
                        Button("Forget This Lamp", role: .destructive) { store.forget(light) }
                            .help("Removes the lamp until it is discovered on the network again.")
                    }
                    if light.kind == .nanoleaf {
                        NanoleafActions(light: light)
                    }
                }
            }
            Section {
                Button("Search Again") { store.searchAgain() }
            } footer: {
                Text("A Key Light Neo is found over USB. Govee lamps need LAN Control turned on in the Govee Home app, under the device's settings. Nanoleaf lights, like the Secretlab MAGRGB, are paired once: click Pair, then choose Connect to API in the light's advanced settings in the Nanoleaf app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
    }

    private func name(for light: Light) -> Binding<String> {
        Binding(get: { light.customName ?? "" }, set: { store.rename(light, to: $0) })
    }

    private func status(of light: Light) -> String {
        if let text = light.availabilityText { return text }
        return light.isOn ? "On" : "Off"
    }
}

private struct NanoleafActions: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        HStack {
            switch light.pairing {
            case .needed:
                Button("Pair") { store.pair(light) }
                    .help("Waits two minutes for Connect to API in the Nanoleaf app.")
            case .waiting:
                Button("Cancel Pairing") { store.cancelPairing(light) }
            case nil:
                EmptyView()
            }
            Spacer()
            Button("Forget This Light", role: .destructive) { store.forget(light) }
                .help("Removes the light and its pairing. While it's on the network it comes back, ready to pair again.")
        }
    }
}

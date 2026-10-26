import LightsKit
import SwiftUI

/// Rename presets, pick their icons, choose which lights each one sets and take a light's look
/// from what it shows now.
struct PresetsSettingsView: View {
    @Environment(PresetStore.self) private var presets
    @Environment(LightStore.self) private var store

    var body: some View {
        Form {
            if presets.presets.isEmpty {
                Section {
                    Text("No presets yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(presets.presets.enumerated()), id: \.element.id) { index, preset in
                PresetSection(preset: preset, canMoveUp: index > 0, canMoveDown: index < presets.presets.count - 1)
            }
            Section {
                HStack {
                    Button("New Preset from Current Lights") {
                        presets.saveCurrentLights(named: "Preset \(presets.presets.count + 1)")
                    }
                    .disabled(store.reachableLights.isEmpty)
                    Spacer()
                    if !presets.missingBuiltIns.isEmpty {
                        Button("Restore Built-in Presets") { presets.restoreBuiltIns() }
                            .help(presets.missingBuiltIns.map(\.name).formatted())
                    }
                }
            } footer: {
                Text("Apply a preset from the lights panel, the menu bar icon's menu or a shortcut (see Shortcuts). Lights a preset leaves out keep what they show. Like any change made by hand, a preset pauses adaptive lighting on the lights it sets until the next sunrise or sunset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 630)
    }
}

private struct PresetSection: View {
    @Environment(PresetStore.self) private var presets
    @Environment(LightStore.self) private var store
    let preset: Preset
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        Section {
            TextField("Name", text: binding(\.name))
            Picker("Icon", selection: binding(\.symbol)) {
                ForEach(PresetStore.symbols, id: \.name) { symbol in
                    Label(symbol.title, systemImage: symbol.name).tag(symbol.name)
                }
            }
            ForEach(store.lights) { light in
                PresetLightRow(preset: preset, light: light)
            }
            HStack {
                Button("Update to Current Lights") { presets.updateToCurrentLights(preset) }
                    .help("Take what the lights this preset sets show now")
                    .disabled(store.reachableLights.isEmpty)
                Spacer()
                Button("Move Up", systemImage: "arrow.up") { presets.move(preset, by: -1) }
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "arrow.down") { presets.move(preset, by: 1) }
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveDown)
                Button("Delete", role: .destructive) { presets.delete(preset) }
            }
        } header: {
            Label(preset.displayName, systemImage: preset.symbol)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Preset, Value>) -> Binding<Value> {
        Binding(
            get: { preset[keyPath: keyPath] },
            set: { value in
                var edited = preset
                edited[keyPath: keyPath] = value
                presets.update(edited)
            }
        )
    }
}

/// Whether the preset sets one light, and to what.
private struct PresetLightRow: View {
    @Environment(PresetStore.self) private var presets
    let preset: Preset
    let light: Light

    var body: some View {
        let look = preset.look(for: light.state)
        LabeledContent {
            HStack(spacing: 10) {
                Button("Use Current") { presets.setLook(Preset.Look(showing: light.state), for: light, in: preset) }
                    .controlSize(.small)
                    .disabled(!light.isReachable)
                    .help("Use what \(light.name) shows now")
                Toggle("Set \(light.name)", isOn: Binding(
                    get: { look != nil },
                    set: { presets.setLook($0 ? Preset.Look(showing: light.state) : nil, for: light, in: preset) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(look == nil && !light.isReachable)
            }
        } label: {
            Text(light.name)
            HStack(spacing: 4) {
                if case let .color(_, rgb) = look {
                    Circle()
                        .fill(Color(rgb))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 8, height: 8)
                }
                Text(look?.summary(for: light) ?? "Left as it is")
            }
        }
    }
}

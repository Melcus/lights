import AppKit
import LightsKit
import SwiftUI

/// Presets in the panel: one click sets every light, and the preset the lights show now is lit.
/// The last button saves what the lights show as a new preset.
struct PresetBar: View {
    @Environment(PresetStore.self) private var presets
    @Environment(LightStore.self) private var store
    let editPresets: () -> Void
    @State private var isNaming = false

    var body: some View {
        Group {
            if isNaming {
                NamingRow { name in
                    presets.saveCurrentLights(named: name)
                    isNaming = false
                } cancel: {
                    isNaming = false
                }
                .transition(.opacity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 10) {
                    ForEach(presets.presets) { preset in
                        PresetButton(
                            preset: preset, tint: preset.tint(for: store.lights), isActive: presets.isActive(preset),
                            help: preset.summary(for: store.lights)
                        ) {
                            presets.apply(preset)
                        }
                        .disabled(store.reachableLights.isEmpty)
                        .contextMenu {
                            Button("Update to Current Lights") { presets.updateToCurrentLights(preset) }
                            Button("Edit Presets…", action: editPresets)
                            Divider()
                            Button("Delete", role: .destructive) { presets.delete(preset) }
                        }
                    }
                    NewPresetButton {
                        withAnimation(.smooth(duration: 0.2)) { isNaming = true }
                    }
                    .disabled(store.reachableLights.isEmpty)
                }
                .transition(.opacity)
            }
        }
        .padding(10)
        .modifier(ModuleBackground())
        // The panel closes when it loses focus; don't come back to a half-named preset.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isNaming = false
        }
    }
}

private struct PresetButton: View {
    let preset: Preset
    let tint: Color
    let isActive: Bool
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isActive ? Color.black.opacity(0.72) : Color.primary)
                    .background {
                        Circle().fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(.primary.opacity(0.09)))
                    }
                    .shadow(color: isActive ? tint.opacity(0.6) : .clear, radius: 8)
                Text(preset.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .accessibilityLabel(preset.displayName)
        .accessibilityHint("Applies the preset")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .animation(.smooth(duration: 0.25), value: isActive)
    }
}

private struct NewPresetButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                    .background {
                        Circle().strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                Text("New")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(PressableButtonStyle())
        .help("Save what the lights show now as a new preset")
        .accessibilityLabel("New preset from the lights as they are now")
    }
}

/// Names the preset about to be saved. Return saves, Escape cancels.
private struct NamingRow: View {
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Save what the lights show now as a preset.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                    .focused($isFocused)
                    .onSubmit { if !trimmed.isEmpty { save(trimmed) } }
                    .onExitCommand(perform: cancel)
                capsuleButton("Cancel", isProminent: false, action: cancel)
                capsuleButton("Save", isProminent: true) { save(trimmed) }
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 2)
        // Focus only takes once the panel has resized around the row.
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isFocused = true
        }
    }

    private func capsuleButton(_ title: String, isProminent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .background {
                    Capsule().fill(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.1)))
                }
        }
        .buttonStyle(PressableButtonStyle())
    }
}

extension Preset {
    /// The name as shown; a preset whose name was cleared still needs one.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// One line per light it sets, for tooltips.
    func summary(for lights: [Light]) -> String {
        let lines = lights.compactMap { light in look(for: light.state).map { "\(light.name): \($0.summary(for: light))" } }
        return lines.isEmpty ? "Leaves every light as it is" : lines.joined(separator: "\n")
    }
}

extension Preset.Look {
    /// "40% · 5000 K", "60% · Colour", "64% · Northern Lights" or "Off", as `light` would show it.
    func summary(for light: Light) -> String {
        let state = light.state
        return switch self {
        case .off: "Off"
        case let .white(brightness, kelvin): "\(state.fittedBrightness(brightness))% · \(state.fittedKelvin(kelvin)) K"
        case let .color(brightness, _): "\(state.fittedBrightness(brightness))% · Colour"
        case let .scene(brightness, name): "\(state.fittedBrightness(brightness))% · \(name)"
        }
    }
}

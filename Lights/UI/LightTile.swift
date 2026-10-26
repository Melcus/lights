import LightsKit
import SwiftUI

/// One light, laid out like a Control Center module: the orb toggles, sliders adjust.
struct LightTile: View {
    @Environment(LightStore.self) private var store
    @Environment(AdaptiveLighting.self) private var adaptive
    let light: Light

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PowerOrb(light: light) { store.toggle(light) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if adaptive.isEnabled, light.isReachable {
                    AutoPill(light: light)
                }
                if light.pairing == .waiting {
                    ProgressView()
                        .controlSize(.small)
                } else if light.availability == .offline, light.pairing == nil {
                    Button("Retry", systemImage: "arrow.clockwise") { store.searchAgain() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Look for \(light.name) again")
                }
            }

            if light.isReachable {
                VStack(spacing: 7) {
                    BrightnessSlider(light: light)
                    TemperatureSlider(light: light)
                    if light.capabilities.supportsColor {
                        ColorSwatches(light: light)
                    }
                    if !light.effects.isEmpty {
                        ScenePicker(light: light)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if let pairing = light.pairing {
                PairingPrompt(light: light, pairing: pairing)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .modifier(ModuleBackground(tint: light.tint.opacity(light.isOn ? 0.14 : 0)))
        .animation(.smooth(duration: 0.25), value: light.isOn)
        .animation(.smooth(duration: 0.25), value: light.isReachable)
        .animation(.smooth(duration: 0.25), value: light.color)
        .animation(.smooth(duration: 0.25), value: light.effect)
        .animation(.smooth(duration: 0.25), value: light.pairing)
    }

    private var status: String {
        if let text = light.availabilityText { return text }
        guard light.isOn else { return "Off" }
        let tone = light.effect ?? (light.color == nil ? "\(light.kelvin) K" : "Colour")
        return "\(light.brightness)% · \(tone)"
    }
}

/// A Nanoleaf light hands out a token only while its pairing window is open.
private struct PairingPrompt: View {
    @Environment(LightStore.self) private var store
    let light: Light
    let pairing: Light.Pairing

    var body: some View {
        HStack(spacing: 10) {
            Text(pairing == .waiting
                ? "Now open the light in the Nanoleaf app and choose Advanced settings › Connect to API."
                : "Click Pair, then choose Connect to API in the light's advanced settings in the Nanoleaf app.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                pairing == .waiting ? store.cancelPairing(light) : store.pair(light)
            } label: {
                Text(pairing == .waiting ? "Cancel" : "Pair")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .foregroundStyle(pairing == .waiting ? Color.primary : Color.white)
                    .background {
                        Capsule().fill(pairing == .waiting ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(Color.accentColor))
                    }
            }
            .buttonStyle(PressableButtonStyle())
            .help(pairing == .waiting ? "Stop waiting for the pairing window" : "Ask \(light.name) for access while its pairing window is open")
        }
    }
}

/// Whether a light follows adaptive lighting. Clicking always (re)applies it; a manual change pauses it.
private struct AutoPill: View {
    @Environment(AdaptiveLighting.self) private var adaptive
    let light: Light

    var body: some View {
        let following = adaptive.follows(light)
        Button {
            adaptive.resume(light)
        } label: {
            Text("Auto")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(following ? adaptive.phase.accentForeground : Color.secondary)
                .background {
                    Capsule().fill(following ? AnyShapeStyle(adaptive.phase.accent) : AnyShapeStyle(.primary.opacity(0.06)))
                }
                .overlay { Capsule().strokeBorder(.primary.opacity(following ? 0 : 0.15)) }
        }
        .buttonStyle(PressableButtonStyle())
        .help(help(following: following))
        .accessibilityLabel(following ? "Adaptive lighting on for \(light.name)" : "Adaptive lighting paused for \(light.name)")
        .animation(.smooth(duration: 0.2), value: following)
    }

    private func help(following: Bool) -> String {
        if following { return "Following adaptive lighting. Click to re-apply it now; changing the light by hand pauses it." }
        if let effect = light.effect { return "Playing \(effect). Click to switch back to adaptive white." }
        if light.color != nil { return "Showing a colour. Click to switch back to adaptive white." }
        if let until = adaptive.pausedUntil[light.id] {
            return "Paused after a manual change until \(until.formatted(date: .omitted, time: .shortened)). Click to follow adaptive lighting again."
        }
        return "Click to follow adaptive lighting."
    }
}

private struct PowerOrb: View {
    let light: Light
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: light.kind.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(light.isOn ? Color.black.opacity(0.7) : Color.secondary)
                .background {
                    Circle()
                        .fill(light.isOn ? AnyShapeStyle(light.tint) : AnyShapeStyle(.primary.opacity(0.1)))
                        .overlay(Circle().strokeBorder(.black.opacity(light.isOn ? 0.08 : 0)))
                }
                .shadow(color: light.isOn ? light.tint.opacity(0.65) : .clear, radius: 9)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!light.isReachable)
        .help(light.isOn ? "Turn off" : "Turn on")
        .accessibilityLabel(light.isOn ? "Turn off \(light.name)" : "Turn on \(light.name)")
    }
}

private struct BrightnessSlider: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        let range = light.capabilities.brightnessRange
        let span = Double(range.upperBound - range.lowerBound)
        CapsuleSlider(
            value: Binding(
                get: { Double(light.brightness - range.lowerBound) / span },
                set: { store.setBrightness(range.lowerBound + Int(($0 * span).rounded()), for: light) }
            ),
            limit: Double(light.brightnessLimit - range.lowerBound) / span,
            limitLabel: "USB power limit",
            icon: "sun.max.fill",
            label: "Brightness",
            valueText: "\(light.brightness)%",
            style: .fill(light.isOn ? light.tint : Color.primary.opacity(0.22))
        ) {
            Color.primary.opacity(0.1)
        }
        .help(light.maxBrightness.map { "This power source limits the light to \($0)%. A 3 A USB-C supply allows full brightness." } ?? "")
    }
}

private struct TemperatureSlider: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        let range = light.capabilities.kelvinRange
        let span = Double(range.upperBound - range.lowerBound)
        CapsuleSlider(
            value: Binding(
                get: { Double(light.kelvin - range.lowerBound) / span },
                set: { store.setKelvin(range.lowerBound + Int(($0 * span / 50).rounded()) * 50, for: light) }
            ),
            icon: "thermometer.medium",
            label: "Colour temperature",
            valueText: "\(light.kelvin) K",
            style: .knob(isActive: light.color == nil && light.effect == nil)
        ) {
            let isActive = light.isOn && light.color == nil && light.effect == nil
            LinearGradient(colors: Self.stops(for: range), startPoint: .leading, endPoint: .trailing)
                .saturation(isActive ? 1 : 0)
                .opacity(isActive ? 1 : 0.5)
        }
    }

    private static func stops(for range: ClosedRange<Int>) -> [Color] {
        stride(from: 0.0, through: 1.0, by: 0.25).map {
            let kelvin = range.lowerBound + Int(Double(range.upperBound - range.lowerBound) * $0)
            return Color(RGB.tint(kelvin: kelvin))
        }
    }
}

private struct ColorSwatches: View {
    @Environment(LightStore.self) private var store
    let light: Light

    private static let presets: [(name: String, color: RGB)] = [
        ("Red", RGB(r: 255, g: 45, b: 35)),
        ("Orange", RGB(r: 255, g: 125, b: 0)),
        ("Yellow", RGB(r: 255, g: 238, b: 0)),
        ("Green", RGB(r: 40, g: 215, b: 80)),
        ("Teal", RGB(r: 0, g: 200, b: 190)),
        ("Blue", RGB(r: 30, g: 100, b: 255)),
        ("Purple", RGB(r: 150, g: 65, b: 255)),
        ("Pink", RGB(r: 255, g: 60, b: 170)),
        ("White", .white),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.presets, id: \.name) { preset in
                let isSelected = light.color == preset.color
                // White needs a darker rim to stand out on light glass.
                let rim: Color = preset.color == .white ? Color.primary.opacity(0.25) : Color.white.opacity(0.3)
                Button {
                    store.setColor(preset.color, for: light)
                } label: {
                    Circle()
                        .fill(Color(preset.color))
                        .overlay(Circle().strokeBorder(rim, lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5))
                }
                .buttonStyle(PressableButtonStyle())
                .frame(maxWidth: .infinity)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.top, 2)
    }
}

/// Scenes stored on the light, shown as their colours. Collapsed it names the one playing.
private struct ScenePicker: View {
    @Environment(LightStore.self) private var store
    let light: Light
    @AppStorage("scenesExpanded") private var isExpanded = false

    var body: some View {
        VStack(spacing: 7) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Scenes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let effect = light.effect {
                        PaletteStrip(colors: light.effectPalette ?? [])
                            .frame(width: 22, height: 8)
                            .clipShape(Capsule())
                        Text(effect)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide scenes" : "Show scenes")

            if isExpanded {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(light.effects) { effect in
                        SceneChip(effect: effect, isSelected: light.effect == effect.name) {
                            store.setEffect(effect.name, for: light)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct SceneChip: View {
    let effect: Light.Effect
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(effect.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if effect.isRhythm {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                PaletteStrip(colors: effect.palette)
                    .overlay(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(2)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .help(effect.isRhythm ? "\(effect.name) reacts to sound" : effect.name)
        .accessibilityLabel(effect.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A scene's colours side by side, blended.
private struct PaletteStrip: View {
    let colors: [RGB]

    var body: some View {
        switch colors.count {
        case 0: Color.primary.opacity(0.2)
        case 1: Color(colors[0])
        default: LinearGradient(colors: colors.map(Color.init), startPoint: .leading, endPoint: .trailing)
        }
    }
}

private extension Light.Kind {
    var symbolName: String {
        switch self {
        case .keyLight: "lamp.desk.fill"
        case .govee: "lamp.floor.fill"
        case .nanoleaf: "light.strip.2.fill"
        }
    }
}

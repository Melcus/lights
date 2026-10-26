import AppKit
import SwiftUI

/// Content of the menu bar panel. The glass itself is drawn by `GlassPanel`.
struct PanelView: View {
    @Environment(LightStore.self) private var store
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader()
            if store.lights.isEmpty {
                SearchingCard()
            } else {
                ForEach(store.lights) { light in
                    LightTile(light: light)
                }
            }
            PanelFooter(openSettings: openSettings)
        }
        .padding(10)
        .frame(width: 320)
        .animation(.smooth(duration: 0.3), value: store.lights.map(\.id))
    }
}

private struct PanelHeader: View {
    @Environment(LightStore.self) private var store

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lights")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            AdaptiveButton()
            MasterPowerButton(isOn: store.anyOn) { store.toggleAll() }
                .disabled(store.reachableLights.isEmpty)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .animation(.smooth, value: summary)
    }

    private var summary: String {
        let reachable = store.reachableLights
        if store.lights.isEmpty { return "Looking for lights…" }
        if reachable.isEmpty { return "No lights responding" }
        let on = reachable.count { $0.isOn }
        return switch on {
        case 0: "All off"
        case reachable.count: reachable.count == 1 ? "On" : "All on"
        default: "\(on) of \(reachable.count) on"
        }
    }
}

/// Turns adaptive lighting on or off; shows the sun's phase.
private struct AdaptiveButton: View {
    @Environment(AdaptiveLighting.self) private var adaptive

    var body: some View {
        let isOn = adaptive.isEnabled
        let phase = adaptive.phase
        Button { adaptive.isEnabled.toggle() } label: {
            Image(systemName: isOn ? phase.symbolName : "sun.horizon")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn ? phase.accentForeground : Color.primary)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(phase.accent) : AnyShapeStyle(.primary.opacity(0.09)))
                }
                .shadow(color: isOn ? phase.accent.opacity(0.55) : .clear, radius: 8)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .help(isOn
            ? "Adaptive lighting is on: \(adaptive.targetSummary), \(adaptive.phase.summary). Click to turn it off."
            : "Turn on adaptive lighting, which follows daylight like Night Shift.")
        .accessibilityLabel(isOn ? "Turn off adaptive lighting" : "Turn on adaptive lighting")
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

private struct MasterPowerButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.primary)
                .background {
                    Circle().fill(isOn ? AnyShapeStyle(Color.warmGlow) : AnyShapeStyle(.primary.opacity(0.09)))
                }
                .shadow(color: isOn ? .warmGlow.opacity(0.65) : .clear, radius: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .help(isOn ? "Turn all lights off" : "Turn all lights on")
        .accessibilityLabel(isOn ? "Turn all lights off" : "Turn all lights on")
        .animation(.smooth(duration: 0.25), value: isOn)
    }
}

private struct SearchingCard: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for lights…")
                .font(.system(size: 12, weight: .medium))
            Text("Plug in a Key Light Neo, turn on LAN Control for Govee lamps in the Govee Home app, or put a Nanoleaf light on this Wi-Fi.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .modifier(ModuleBackground())
    }
}

/// Control Center-style module platter, lighter than the glass in both appearances.
struct ModuleBackground: ViewModifier {
    var tint: Color = .clear
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55))
                .overlay { shape.fill(tint) }
        }
    }
}

private struct PanelFooter: View {
    let openSettings: () -> Void

    var body: some View {
        HStack {
            FooterButton(title: "Settings…", systemImage: "gearshape", action: openSettings)
            Spacer()
            FooterButton(title: "Quit", systemImage: nil) { NSApp.terminate(nil) }
        }
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.primary.opacity(isHovered ? 0.08 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
    }
}

/// Shrinks slightly while pressed, like system controls on glass.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

import SwiftUI

/// Thick Control Center-style slider: a capsule track with its icon inside.
struct CapsuleSlider<Track: View>: View {
    enum Style {
        /// Fills from the leading edge (brightness).
        case fill(Color)
        /// A knob over a meaningful track (colour temperature); dimmed when inactive.
        case knob(isActive: Bool)
    }

    @Binding var value: Double
    /// Highest reachable position; the rest of the track is marked unavailable.
    var limit: Double = 1
    var limitLabel: String?
    let icon: String
    let label: String
    let valueText: String
    let style: Style
    @ViewBuilder let track: Track

    private let height: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - height, 1)
            let position = min(max(value, 0), limit)

            ZStack(alignment: .leading) {
                track
                if limit < 1 {
                    let blockedWidth = travel * (1 - limit) + height / 2
                    UnavailableRegion(label: blockedWidth > 110 ? limitLabel : nil)
                        .frame(width: blockedWidth)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.55))
                    .padding(.leading, 8)
                    .zIndex(1)
                switch style {
                case .fill(let color):
                    Capsule()
                        .fill(color)
                        .frame(width: height + travel * position)
                case .knob(let isActive):
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .frame(width: height - 6, height: height - 6)
                        .opacity(isActive ? 1 : 0.7)
                        .offset(x: 3 + travel * position)
                        .zIndex(2)
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    value = min(max((drag.location.x - height / 2) / travel, 0), limit)
                }
            )
        }
        .frame(height: height)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...max(limit, 0.01)) { Text(label) }
        }
        .accessibilityValue(valueText)
    }
}

/// Hatched end of a track the device won't go to, e.g. above a power-limited brightness.
private struct UnavailableRegion: View {
    let label: String?

    var body: some View {
        Canvas { context, size in
            var stripes = Path()
            for x in stride(from: -size.height, to: size.width, by: 5) {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(stripes, with: .color(.primary.opacity(0.1)), lineWidth: 1)
        }
        .overlay {
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(.background.opacity(0.6)))
            }
        }
    }
}

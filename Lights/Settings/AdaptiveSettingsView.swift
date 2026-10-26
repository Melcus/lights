import LightsKit
import SwiftUI

struct AdaptiveSettingsView: View {
    @Environment(AdaptiveLighting.self) private var adaptive

    var body: some View {
        @Bindable var adaptive = adaptive
        Form {
            Section {
                Toggle("Adaptive lighting", isOn: $adaptive.isEnabled)
            } footer: {
                Text("Like Night Shift for your lights: daylight white while the sun is up, warming through sunset to a cosy white at night, with brightness following along if you like. Only lights that are on and showing white are adjusted. Changing a light by hand pauses it until the next sunrise or sunset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Colour temperature") {
                SliderRow(title: "Daytime", value: $adaptive.dayKelvin, range: 4000...6500, step: 100, suffix: " K")
                SliderRow(title: "Night", value: $adaptive.nightKelvin, range: 2200...4000, step: 100, suffix: " K")
            }

            Section {
                Toggle("Adjust brightness", isOn: $adaptive.adjustsBrightness)
                SliderRow(title: "Daytime", value: $adaptive.dayBrightness, range: 10...100, step: 5, suffix: "%")
                    .disabled(!adaptive.adjustsBrightness)
                SliderRow(title: "Night", value: $adaptive.nightBrightness, range: 10...100, step: 5, suffix: "%")
                    .disabled(!adaptive.adjustsBrightness)
            } header: {
                Text("Brightness")
            } footer: {
                Text("A share of each light's own maximum, so a light limited by its power source scales with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DaylightCurves()
                if let times = adaptive.sunTimesToday {
                    LabeledContent("Sunrise", value: times.sunrise.formatted(date: .omitted, time: .shortened))
                    LabeledContent("Sunset", value: times.sunset.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("Right now", value: "\(adaptive.targetSummary), \(adaptive.phase.summary)")
            } header: {
                Text("Today")
            } footer: {
                Text("Sun times for \(adaptive.place.name), based on your time zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 790)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int(($0 / Double(step)).rounded()) * step }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .frame(width: 170)
                Text(verbatim: "\(value)\(suffix)") // no locale grouping, matching the panel
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }
}

/// The day's colour temperature, and brightness when adjusted, from midnight to midnight with a
/// marker for now.
private struct DaylightCurves: View {
    @Environment(AdaptiveLighting.self) private var adaptive

    var body: some View {
        let profile = adaptive.dayProfile()
        VStack(alignment: .leading, spacing: 6) {
            strip(label: "Colour", stops: profile.map {
                Gradient.Stop(color: Color(RGB.tint(kelvin: $0.kelvin)), location: $0.fraction)
            })
            if adaptive.adjustsBrightness {
                strip(label: "Brightness", stops: profile.map {
                    Gradient.Stop(color: Color.warmGlow.opacity(Double($0.brightness) / 100), location: $0.fraction)
                })
            }
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                    if hour < 24 { Spacer() }
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.leading, 72)
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func strip(label: String, stops: [Gradient.Stop]) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 3, height: geometry.size.height + 8)
                            .offset(x: geometry.size.width * adaptive.dayFraction - 1.5)
                    }
            }
            .frame(height: 14)
        }
    }
}

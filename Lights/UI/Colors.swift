import LightsKit
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    static let warmGlow = Color(RGB(kelvin: 3000).mixed(with: .white, amount: 0.35))
}

extension RGB {
    static let white = RGB(r: 255, g: 255, b: 255)

    func mixed(with other: RGB, amount: Double) -> RGB {
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * amount).rounded()) }
        return RGB(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }

    /// Accent for a white temperature. Real black-body colours fade to white past 5000 K and
    /// disappear on light glass, so the cool end is pushed towards ice blue.
    static func tint(kelvin: Int) -> RGB {
        let stops: [(kelvin: Int, color: RGB)] = [
            (2000, RGB(r: 255, g: 159, b: 64)),
            (3000, RGB(r: 255, g: 190, b: 110)),
            (4000, RGB(r: 255, g: 213, b: 145)),
            (5000, RGB(r: 248, g: 226, b: 178)),
            (6000, RGB(r: 205, g: 222, b: 255)),
            (7000, RGB(r: 168, g: 198, b: 255)),
        ]
        guard let upper = stops.firstIndex(where: { $0.kelvin >= kelvin }) else { return stops[stops.count - 1].color }
        guard upper > 0 else { return stops[0].color }
        let (low, high) = (stops[upper - 1], stops[upper])
        return low.color.mixed(with: high.color, amount: Double(kelvin - low.kelvin) / Double(high.kelvin - low.kelvin))
    }

    /// Accent for a colour a light emits. RGB white is a cool white, tinted like one so it shows on
    /// light glass.
    var accent: RGB {
        hueSaturation.saturation < 8 ? .tint(kelvin: 6500) : mixed(with: .white, amount: 0.15)
    }
}

extension Light {
    /// Accent reflecting what the light emits: its RGB colour, its scene's first colour, or its
    /// white temperature.
    var tint: Color {
        let emitted = color ?? effectPalette?.first { max($0.r, $0.g, $0.b) > 60 }
        return Color(emitted?.accent ?? .tint(kelvin: kelvin))
    }
}

extension Preset {
    /// Accent for the preset's button: its first colour or scene, else its first white.
    func tint(for lights: [Light]) -> Color {
        let looks = lights.compactMap { look(for: $0.state) } + [colorLights, whiteLights].compactMap { $0 }
        for look in looks {
            switch look {
            case .color(_, let rgb):
                return Color(rgb.accent)
            case .scene(_, let name):
                let palette = lights.lazy.compactMap { $0.effects.first { $0.name == name }?.palette }.first
                if let bright = palette?.first(where: { max($0.r, $0.g, $0.b) > 60 }) { return Color(bright.accent) }
            case .off, .white:
                continue
            }
        }
        for case .white(_, let kelvin) in looks {
            return Color(RGB.tint(kelvin: kelvin))
        }
        return Color.primary.opacity(0.35) // everything off
    }
}

extension AdaptiveLighting.Phase {
    /// Accent for the adaptive controls: sunny by day, amber around sunset and sunrise, indigo at night.
    var accent: Color {
        switch self {
        case .day: Color(red: 1.0, green: 0.82, blue: 0.32)
        case .dusk, .dawn: Color(red: 1.0, green: 0.6, blue: 0.3)
        case .night: Color(red: 0.38, green: 0.4, blue: 0.86)
        }
    }

    var accentForeground: Color {
        self == .night ? .white : .black.opacity(0.72)
    }
}

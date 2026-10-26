import Foundation

/// 8-bit sRGB colour; the JSON shape matches Govee's `{"r":…, "g":…, "b":…}`.
public struct RGB: Codable, Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
    }

    /// Colour from hue, saturation and brightness, each in 0...1 (hue wraps).
    public init(hue: Double, saturation: Double = 1, brightness: Double = 1) {
        let h = (hue - hue.rounded(.down)) * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double) = switch Int(h) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let base = brightness - chroma
        func channel(_ value: Double) -> Int { Int(((value + base) * 255).rounded()) }
        self.init(r: channel(red), g: channel(green), b: channel(blue))
    }

    /// "FF8300" or "#FF8300".
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(r: value >> 16 & 0xFF, g: value >> 8 & 0xFF, b: value & 0xFF)
    }

    /// Hue in degrees and saturation in percent, the way Nanoleaf expresses colour.
    public var hueSaturation: (hue: Int, saturation: Int) {
        let (red, green, blue) = (Double(r) / 255, Double(g) / 255, Double(b) / 255)
        let maximum = max(red, green, blue), delta = maximum - min(red, green, blue)
        guard delta > 0 else { return (0, 0) }
        let sector: Double = switch maximum {
        case red: ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: (blue - red) / delta + 2
        default: (red - green) / delta + 4
        }
        let degrees = (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
        return (Int(degrees.rounded()) % 360, Int((delta / maximum * 100).rounded()))
    }

    /// Approximate colour of a black-body light source (Tanner Helland's fit), for tinting UI.
    public init(kelvin: Int) {
        let t = Double(min(max(kelvin, 1000), 40000)) / 100
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        self.init(r: Int(red.rounded()), g: Int(green.rounded()), b: Int(blue.rounded()))
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }
}

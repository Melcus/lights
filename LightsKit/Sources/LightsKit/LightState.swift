import Foundation

/// A snapshot of one light for the rules in this package (adaptive lighting, presets): what it
/// shows and what it can do. The app owns the live lights.
public struct LightState: Equatable, Sendable {
    public var id: String
    public var isReachable: Bool
    public var isOn: Bool
    public var brightness: Int
    public var kelvin: Int
    /// Set while the light shows an RGB colour rather than white.
    public var color: RGB?
    /// Set while the light plays a scene.
    public var scene: String?
    public var brightnessRange: ClosedRange<Int>
    /// The most the light can do right now, e.g. a Key Light Neo on weak USB power.
    public var brightnessLimit: Int
    public var kelvinRange: ClosedRange<Int>
    public var supportsColor: Bool
    /// Scenes the light can play; empty until it has reported them.
    public var scenes: [String]

    public init(
        id: String, isReachable: Bool = true, isOn: Bool, brightness: Int, kelvin: Int, color: RGB? = nil,
        scene: String? = nil, brightnessRange: ClosedRange<Int> = 1...100, brightnessLimit: Int? = nil,
        kelvinRange: ClosedRange<Int> = 2000...7000, supportsColor: Bool = false, scenes: [String] = []
    ) {
        self.id = id
        self.isReachable = isReachable
        self.isOn = isOn
        self.brightness = brightness
        self.kelvin = kelvin
        self.color = color
        self.scene = scene
        self.brightnessRange = brightnessRange
        self.brightnessLimit = min(brightnessLimit ?? brightnessRange.upperBound, brightnessRange.upperBound)
        self.kelvinRange = kelvinRange
        self.supportsColor = supportsColor
        self.scenes = scenes
    }

    /// Neither a colour nor a scene.
    public var showsWhite: Bool { color == nil && scene == nil }

    public func fittedBrightness(_ value: Int) -> Int {
        min(max(value, brightnessRange.lowerBound), brightnessLimit)
    }

    public func fittedKelvin(_ value: Int) -> Int {
        min(max(value, kelvinRange.lowerBound), kelvinRange.upperBound)
    }
}

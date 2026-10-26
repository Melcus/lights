import Foundation

/// A saved look for several lights at once, like "Call" or "Relax".
public struct Preset: Codable, Hashable, Identifiable, Sendable {
    /// What a preset does with one light. Brightness is in the light's own percent, fitted to what it
    /// can do when applied.
    public enum Look: Codable, Hashable, Sendable {
        case off
        case white(brightness: Int, kelvin: Int)
        case color(brightness: Int, rgb: RGB)
        case scene(brightness: Int, name: String)
    }

    /// One change that brings a light to its look, in order.
    public enum Step: Equatable, Sendable {
        case power(Bool)
        case kelvin(Int)
        case color(RGB)
        case scene(String)
        case brightness(Int)
    }

    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Looks for particular lights, by light ID. Lights without one keep what they show.
    public var lights: [String: Look]
    /// For lights not in `lights`, by what they can show. The built-in presets use these so they suit
    /// whatever lights there are; giving one light its own look turns them into per-light looks.
    public var whiteLights: Look?
    public var colorLights: Look?

    public init(
        id: UUID = UUID(), name: String, symbol: String, lights: [String: Look] = [:],
        whiteLights: Look? = nil, colorLights: Look? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.lights = lights
        self.whiteLights = whiteLights
        self.colorLights = colorLights
    }

    /// A preset with what the lights in reach show now.
    public init(capturing lights: [LightState], name: String, symbol: String) {
        let looks = lights.filter(\.isReachable).map { ($0.id, Look(showing: $0)) }
        self.init(name: name, symbol: symbol, lights: Dictionary(looks) { first, _ in first })
    }

    /// What this preset does with `light`, or nil when it leaves the light alone.
    public func look(for light: LightState) -> Look? {
        lights[light.id] ?? (light.supportsColor ? colorLights : whiteLights)
    }

    /// The changes that make `light` show this preset, fitted to what the light can do: white within
    /// its range, brightness within its limit, and no colour or scene it can't show.
    public func steps(for light: LightState) -> [Step] {
        guard light.isReachable, let look = look(for: light) else { return [] }
        let switchOn: [Step] = light.isOn ? [] : [.power(true)]
        switch look {
        case .off:
            return light.isOn ? [.power(false)] : []
        case let .white(brightness, kelvin):
            return switchOn + [.kelvin(light.fittedKelvin(kelvin)), .brightness(light.fittedBrightness(brightness))]
        case let .color(brightness, rgb):
            let color: [Step] = light.supportsColor ? [.color(rgb)] : []
            return switchOn + color + [.brightness(light.fittedBrightness(brightness))]
        case let .scene(brightness, name):
            // A light that hasn't listed its scenes yet gets the benefit of the doubt.
            let scene: [Step] = light.scenes.isEmpty || light.scenes.contains(name) ? [.scene(name)] : []
            return switchOn + scene + [.brightness(light.fittedBrightness(brightness))]
        }
    }

    /// Whether the lights show this preset now. Only lights it changes and that are in reach count.
    /// Brightness must be exact (lights report the percent they were sent); temperature and colour
    /// allow for the rounding lights do (mireds, hue steps).
    public func matches(_ lights: [LightState]) -> Bool {
        let covered = lights.compactMap { light in look(for: light).map { (light, $0) } }.filter { $0.0.isReachable }
        return !covered.isEmpty && covered.allSatisfy { Self.light($0.0, shows: $0.1) }
    }

    /// Gives one light its own look, or with nil leaves it out. Per-kind looks become per-light
    /// looks for `lights` first, so the other lights keep theirs.
    public mutating func setLook(_ look: Look?, forLight id: String, among lights: [LightState]) {
        if whiteLights != nil || colorLights != nil {
            for light in lights where self.lights[light.id] == nil {
                self.lights[light.id] = self.look(for: light)
            }
            whiteLights = nil
            colorLights = nil
        }
        self.lights[id] = look
    }

    private static func light(_ light: LightState, shows look: Look) -> Bool {
        switch look {
        case .off:
            return !light.isOn
        case let .white(brightness, kelvin):
            return light.isOn && light.showsWhite && light.brightness == light.fittedBrightness(brightness)
                && isClose(kelvin: light.kelvin, light.fittedKelvin(kelvin))
        case let .color(brightness, rgb):
            guard light.isOn, light.brightness == light.fittedBrightness(brightness) else { return false }
            guard light.supportsColor else { return true } // it only takes the brightness
            return light.color.map { isClose($0, rgb) } ?? false
        case let .scene(brightness, name):
            return light.isOn && light.scene == name && light.brightness == light.fittedBrightness(brightness)
        }
    }

    /// Elgato and Nanoleaf store temperature in whole mireds, so Kelvin comes back a little off
    /// (3000 K reads 3003 K).
    private static func isClose(kelvin a: Int, _ b: Int) -> Bool {
        abs(1_000_000 / Double(max(a, 1)) - 1_000_000 / Double(max(b, 1))) <= 1
    }

    /// Nanoleaf keeps hue and saturation only, and rounds the hue.
    private static func isClose(_ a: RGB, _ b: RGB) -> Bool {
        let (x, y) = (a.hueSaturation, b.hueSaturation)
        if x.saturation < 10, y.saturation < 10 { return true } // both whites
        let hueGap = abs(x.hue - y.hue)
        return min(hueGap, 360 - hueGap) <= 4 && abs(x.saturation - y.saturation) <= 4
    }
}

extension Preset.Look {
    /// What `light` shows now.
    public init(showing light: LightState) {
        if !light.isOn {
            self = .off
        } else if let scene = light.scene {
            self = .scene(brightness: light.brightness, name: scene)
        } else if let color = light.color {
            self = .color(brightness: light.brightness, rgb: color)
        } else {
            self = .white(brightness: light.brightness, kelvin: light.kelvin)
        }
    }
}

extension Preset {
    /// The presets Lights starts with. They go by what each light can show, so they suit any set of
    /// lights, and their IDs are fixed so a deleted one can be restored.
    public static let builtIn: [Preset] = [
        // Bright neutral white on the face, a soft warm room behind.
        Preset(
            id: UUID(uuidString: "6E1F1C2A-37B4-4F0E-9C51-0A11CE000001")!, name: "Call", symbol: "video.fill",
            whiteLights: .white(brightness: 60, kelvin: 5000), colorLights: .white(brightness: 30, kelvin: 3000)
        ),
        // Bright, neutral and even, for working.
        Preset(
            id: UUID(uuidString: "6E1F1C2A-37B4-4F0E-9C51-0A11CE000002")!, name: "Focus", symbol: "scope",
            whiteLights: .white(brightness: 30, kelvin: 4500), colorLights: .white(brightness: 80, kelvin: 4500)
        ),
        // Desk light off, the room dim and warm.
        Preset(
            id: UUID(uuidString: "6E1F1C2A-37B4-4F0E-9C51-0A11CE000003")!, name: "Relax", symbol: "sofa.fill",
            whiteLights: .off, colorLights: .white(brightness: 35, kelvin: 2700)
        ),
        // Desk light off, the room in colour.
        Preset(
            id: UUID(uuidString: "6E1F1C2A-37B4-4F0E-9C51-0A11CE000004")!, name: "Gaming", symbol: "gamecontroller.fill",
            whiteLights: .off, colorLights: .color(brightness: 60, rgb: RGB(r: 150, g: 65, b: 255))
        ),
    ]
}

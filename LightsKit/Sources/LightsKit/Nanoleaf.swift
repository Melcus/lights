import Foundation

/// Nanoleaf's local "OpenAPI", also spoken by the Secretlab MAGRGB strip: JSON over HTTP on port
/// 16021. `POST /api/v1/new`, sent while the controller is in pairing mode, returns a token that
/// authorises every other call (`/api/v1/<token>/…`). Devices announce themselves over Bonjour.
public enum Nanoleaf {
    public static let serviceType = "_nanoleafapi._tcp"
    public static let defaultPort = 16021

    /// Answer to `GET /api/v1/<token>/`. The MAGRGB leaves out the effects, which come from
    /// `effects/select` and `effects/effectsList` instead.
    public struct Device: Decodable, Equatable, Sendable {
        public var name: String
        public var serialNo: String?
        public var model: String?
        public var firmwareVersion: String?
        public var hardwareVersion: String?
        public var state: State
        public var effects: Effects?
    }

    public struct State: Decodable, Equatable, Sendable {
        public var on: Value<Bool>
        public var brightness: Value<Int>
        public var hue: Value<Int>
        public var sat: Value<Int>
        public var ct: Value<Int>
        /// "hs", "ct" or "effect".
        public var colorMode: String
    }

    public struct Value<T: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
        public var value: T
        public var min: Int?
        public var max: Int?
    }

    public struct Effects: Decodable, Equatable, Sendable {
        public var select: String?
        public var effectsList: [String]?
    }

    /// Answer to `requestAllEffects`.
    public struct Animations: Decodable, Equatable, Sendable {
        public var animations: [Animation]
    }

    public struct Animation: Decodable, Equatable, Sendable {
        public var animName: String
        /// "color" for animated colours, "rhythm" for scenes that react to sound.
        public var pluginType: String?
        /// Panels describe colours as HSB…
        public var palette: [PaletteColor]?
        /// …the MAGRGB as "RRGGBB".
        public var hexPalette: [String]?

        public var colors: [RGB] {
            palette?.map(\.rgb) ?? hexPalette?.compactMap(RGB.init(hex:)) ?? []
        }
    }

    public struct PaletteColor: Decodable, Equatable, Sendable {
        public var hue: Double
        public var saturation: Double
        public var brightness: Double

        public var rgb: RGB { RGB(hue: hue / 360, saturation: saturation / 100, brightness: brightness / 100) }
    }

    public enum Command: Equatable, Sendable {
        case power(Bool)
        case brightness(Int)
        case color(RGB)
        case colorTemperature(Int)
        case effect(String)
        case requestAllEffects
    }

    public struct Request: Equatable, Sendable {
        public var method: String
        /// Relative to `/api/v1/<token>/`.
        public var path: String
        public var body: Data?
    }

    public static func request(for command: Command) -> Request {
        switch command {
        case .power(let on):
            put("state", ["on": ["value": on]])
        case .brightness(let value):
            put("state", ["brightness": ["value": min(max(value, 0), 100), "duration": 0]])
        case .color(let color):
            put("state", ["hue": ["value": color.hueSaturation.hue], "sat": ["value": color.hueSaturation.saturation]])
        case .colorTemperature(let kelvin):
            put("state", ["ct": ["value": kelvin]])
        case .effect(let name):
            put("effects", ["select": name])
        case .requestAllEffects:
            put("effects", ["write": ["command": "requestAll"]])
        }
    }

    /// Effect names starting with "*" (like "*Solid*") are internal states, not scenes.
    public static func isScene(_ name: String) -> Bool {
        !name.hasPrefix("*")
    }

    public static func token(fromPairingResponse data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["auth_token"] as? String
    }

    private static func put(_ path: String, _ body: [String: Any]) -> Request {
        // Plain dictionaries of strings, numbers and booleans always serialize.
        Request(method: "PUT", path: path, body: try! JSONSerialization.data(withJSONObject: body, options: .sortedKeys))
    }
}

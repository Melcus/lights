import Foundation

/// Body of `GET/PUT /elgato/lights`; identical over USB and Wi-Fi.
public struct ElgatoLights: Codable, Equatable, Sendable {
    public var numberOfLights: Int
    public var lights: [ElgatoLightState]

    public init(lights: [ElgatoLightState]) {
        numberOfLights = lights.count
        self.lights = lights
    }
}

/// Omitted fields are left unchanged by a PUT.
public struct ElgatoLightState: Codable, Equatable, Sendable {
    public var on: Int?
    public var brightness: Int?
    /// Colour temperature in mireds, see `ElgatoTemperature`.
    public var temperature: Int?

    public init(on: Int? = nil, brightness: Int? = nil, temperature: Int? = nil) {
        self.on = on
        self.brightness = brightness
        self.temperature = temperature
    }
}

public struct ElgatoAccessoryInfo: Decodable, Equatable, Sendable {
    public var productName: String
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var displayName: String?
    public var powerInfo: PowerInfo?

    public struct PowerInfo: Decodable, Equatable, Sendable {
        public var operationMode: Int?
        /// Brightness cap imposed by the current USB power source; higher values are rejected.
        public var maximumBrightness: Int?
    }

    enum CodingKeys: String, CodingKey {
        case productName, serialNumber, firmwareVersion, displayName
        case powerInfo = "power-info"
    }
}

public enum ElgatoMessage {
    public static func request(_ method: String, _ path: String, body: Data? = nil) -> Data {
        var data = Data("\(method) \(path)".utf8)
        if let body {
            data.append(UInt8(ascii: " "))
            data.append(body)
        }
        return data
    }

    public static func setLight(_ state: ElgatoLightState) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // the firmware is order-agnostic; sorting keeps output stable
        // Encoding plain Int fields cannot fail.
        let body = try! encoder.encode(ElgatoLights(lights: [state]))
        return request("PUT", "/elgato/lights", body: body)
    }
}

/// A decoded message from the light.
public enum ElgatoInbound: Equatable, Sendable {
    case lights(ElgatoLights)
    case accessoryInfo(ElgatoAccessoryInfo)
    case error(String)
    case unknown

    /// Responses carry bare JSON, so their meaning comes from the shape of the body.
    /// Notifications are `"<METHOD> <path> <json>"`.
    public static func decode(kind: UInt8, message: Data) -> ElgatoInbound {
        var path: String?
        var json = message
        if kind == ElgatoHID.Kind.notification.rawValue {
            let parts = message.split(separator: UInt8(ascii: " "), maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return .unknown }
            path = String(decoding: parts[1], as: UTF8.self)
            json = Data(parts[2])
        }

        let decoder = JSONDecoder()
        if path == nil || path == "/elgato/lights", let lights = try? decoder.decode(ElgatoLights.self, from: json) {
            return .lights(lights)
        }
        if path == nil || path == "/elgato/accessory-info",
           let info = try? decoder.decode(ElgatoAccessoryInfo.self, from: json) {
            return .accessoryInfo(info)
        }
        if let failure = try? decoder.decode(ErrorBody.self, from: json) {
            return .error(failure.errors.map(\.message).joined(separator: ", "))
        }
        return .unknown
    }

    private struct ErrorBody: Decodable {
        struct Item: Decodable { var message: String }
        var errors: [Item]
    }
}

/// Elgato lights express colour temperature in mireds (143 = 7000 K, 344 = 2900 K).
public enum ElgatoTemperature {
    public static let deviceRange = 143...344
    public static let kelvinRange = 2900...7000

    /// Rounded to 50 K steps, matching Elgato's own apps.
    public static func kelvin(fromDeviceValue value: Int) -> Int {
        let kelvin = 1_000_000 / Double(max(value, 1))
        return Int((kelvin / 50).rounded()) * 50
    }

    public static func deviceValue(fromKelvin kelvin: Int) -> Int {
        let value = Int((1_000_000 / Double(max(kelvin, 1))).rounded())
        return min(max(value, deviceRange.lowerBound), deviceRange.upperBound)
    }
}

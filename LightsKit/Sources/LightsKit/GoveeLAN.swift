import Foundation

/// Govee's documented LAN API. "LAN Control" has to be enabled per device in the Govee Home app.
///
/// Discovery is a multicast `scan`; devices answer, and send status replies, to UDP 4002 on the
/// sender's address. Commands go to the device on UDP 4003 and are not acknowledged.
public enum GoveeLAN {
    public static let multicastAddress = "239.255.255.250"
    public static let scanPort: UInt16 = 4001
    public static let listenPort: UInt16 = 4002
    public static let commandPort: UInt16 = 4003

    public enum Command: Equatable, Sendable {
        case scan
        case status
        case power(Bool)
        /// 1...100
        case brightness(Int)
        case color(RGB)
        case colorTemperature(Int)
    }

    public enum Message: Equatable, Sendable {
        case scan(GoveeDevice)
        case status(GoveeStatus)
    }

    public static func encode(_ command: Command) -> Data {
        switch command {
        case .scan:
            encode("scan", ["account_topic": "reserve"])
        case .status:
            encode("devStatus", [String: String]())
        case .power(let on):
            encode("turn", ["value": on ? 1 : 0])
        case .brightness(let value):
            encode("brightness", ["value": min(max(value, 1), 100)])
        case .color(let color):
            encode("colorwc", ColorPayload(color: color, colorTemInKelvin: 0))
        case .colorTemperature(let kelvin):
            // Devices that ignore the Kelvin value still get a matching white.
            encode("colorwc", ColorPayload(color: RGB(kelvin: kelvin), colorTemInKelvin: kelvin))
        }
    }

    public static func decode(_ data: Data) -> Message? {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Envelope<Header>.self, from: data) else { return nil }
        switch header.msg.cmd {
        case "scan":
            return (try? decoder.decode(Envelope<Body<GoveeDevice>>.self, from: data)).map { .scan($0.msg.data) }
        case "devStatus":
            return (try? decoder.decode(Envelope<Body<GoveeStatus>>.self, from: data)).map { .status($0.msg.data) }
        default:
            return nil
        }
    }

    private static func encode(_ cmd: String, _ data: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Encoding string and integer payloads cannot fail.
        return try! encoder.encode(Envelope(msg: Request(cmd: cmd, data: data)))
    }

    fileprivate struct Envelope<M> { var msg: M }
    private struct Request<D: Encodable>: Encodable {
        var cmd: String
        var data: D
    }
    private struct Header: Decodable { var cmd: String }
    private struct Body<D: Decodable>: Decodable { var data: D }

    private struct ColorPayload: Encodable {
        var color: RGB
        var colorTemInKelvin: Int
    }
}

extension GoveeLAN.Envelope: Encodable where M: Encodable {}
extension GoveeLAN.Envelope: Decodable where M: Decodable {}

public struct GoveeDevice: Codable, Equatable, Sendable {
    public var ip: String
    /// Stable device identifier (MAC-like).
    public var device: String
    public var sku: String

    public init(ip: String, device: String, sku: String) {
        self.ip = ip
        self.device = device
        self.sku = sku
    }
}

public struct GoveeStatus: Codable, Equatable, Sendable {
    public var onOff: Int
    public var brightness: Int
    public var color: RGB
    /// 0 when the device shows an RGB colour.
    public var colorTemInKelvin: Int
}

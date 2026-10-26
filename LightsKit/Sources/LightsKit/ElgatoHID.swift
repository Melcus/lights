import Foundation

/// Framing of the USB HID tunnel spoken by Elgato's USB lights (Key Light Neo).
///
/// Reverse engineered from Elgato Control Center 1.9.2 and verified against a Key Light Neo
/// running firmware 1.0.6 (see docs/PROTOCOLS.md). Every report is 512 bytes:
///
///     [0x02 report ID] [packet index] [packet count] [kind] [length lo] [length hi] [payload] [zero padding]
///
/// The payload is text. Requests read `"<METHOD> <path>[ <json>]"`, responses are bare JSON and
/// notifications repeat the request form, e.g. `"GET /elgato/lights {…}"`.
public enum ElgatoHID {
    public static let vendorID = 0x0FD9
    /// USB product IDs of Elgato lights that speak this protocol.
    public static let lightProductIDs: Set<Int> = [0x00A0] // Key Light Neo
    public static let reportID: UInt8 = 0x02
    public static let reportLength = 512
    static let headerLength = 6
    /// Control Center keeps one byte after the payload for a NUL terminator.
    public static let maxPayloadPerReport = reportLength - headerLength - 1

    public enum Kind: UInt8, Sendable {
        case response = 0x00
        case request = 0x03
        case notification = 0x08
    }

    public struct Packet: Equatable, Sendable {
        public var index: Int
        public var count: Int
        public var kind: UInt8
        public var payload: Data
    }

    /// Splits a message into zero-padded output reports, report ID included.
    public static func reports(for message: Data, kind: Kind = .request) -> [Data] {
        let bytes = [UInt8](message)
        let chunks = stride(from: 0, to: max(bytes.count, 1), by: maxPayloadPerReport).map {
            Array(bytes[$0..<min($0 + maxPayloadPerReport, bytes.count)])
        }
        precondition(chunks.count <= Int(UInt8.max), "message too large for the HID tunnel")

        return chunks.enumerated().map { index, chunk in
            var report: [UInt8] = [
                reportID, UInt8(index), UInt8(chunks.count), kind.rawValue,
                UInt8(chunk.count & 0xFF), UInt8(chunk.count >> 8),
            ]
            report += chunk
            report += [UInt8](repeating: 0, count: reportLength - report.count)
            return Data(report)
        }
    }

    /// Parses one input report as IOKit delivers it (report ID first). Bytes past the declared
    /// length are stale firmware buffer contents and are ignored.
    public static func parse(report: Data) -> Packet? {
        let bytes = [UInt8](report)
        guard bytes.count >= headerLength, bytes[0] == reportID else { return nil }
        let index = Int(bytes[1]), count = Int(bytes[2])
        let length = Int(bytes[4]) | Int(bytes[5]) << 8
        guard count > 0, index < count, headerLength + length <= bytes.count else { return nil }
        return Packet(index: index, count: count, kind: bytes[3],
                      payload: Data(bytes[headerLength..<headerLength + length]))
    }
}

/// Joins multi-report messages. Feed packets in arrival order; a message is returned once complete.
public struct ElgatoHIDReassembler: Sendable {
    private var buffer = Data()
    private var nextIndex = 0
    private var kind: UInt8 = 0

    public init() {}

    public mutating func consume(_ packet: ElgatoHID.Packet) -> (kind: UInt8, message: Data)? {
        if packet.index == 0 {
            buffer = Data()
            nextIndex = 0
            kind = packet.kind
        }
        guard packet.index == nextIndex, packet.kind == kind else {
            buffer = Data()
            nextIndex = 0
            return nil
        }
        buffer.append(packet.payload)
        nextIndex += 1
        guard nextIndex == packet.count else { return nil }

        defer {
            buffer = Data()
            nextIndex = 0
        }
        return (kind, buffer)
    }
}

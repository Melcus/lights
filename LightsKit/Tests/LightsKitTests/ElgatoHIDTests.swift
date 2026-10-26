import Foundation
import Testing
@testable import LightsKit

/// Fixtures are the exact reports captured from a Key Light Neo (firmware 1.0.6).
struct ElgatoHIDTests {
    @Test func requestReportMatchesControlCenterFraming() throws {
        let reports = ElgatoHID.reports(for: ElgatoMessage.request("GET", "/elgato/accessory-info"))

        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.count == 512)
        #expect(Array(report.prefix(6)) == [0x02, 0x00, 0x01, 0x03, 0x1A, 0x00])
        #expect(String(decoding: report[6..<32], as: UTF8.self) == "GET /elgato/accessory-info")
        #expect(report[32...].allSatisfy { $0 == 0 })
    }

    @Test func putCarriesJSONBodyAfterPath() {
        let message = ElgatoMessage.setLight(ElgatoLightState(on: 1))
        #expect(String(decoding: message, as: UTF8.self) == #"PUT /elgato/lights {"lights":[{"on":1}],"numberOfLights":1}"#)
    }

    @Test func responseIgnoresStaleBytesAfterDeclaredLength() throws {
        let json = #"{"numberOfLights":1,"lights":[{"on":0,"brightness":30,"temperature":143}]}"#
        var bytes: [UInt8] = [0x02, 0x00, 0x01, 0x00, 0x4A, 0x00] + Array(json.utf8)
        bytes += Array(#"ure":230,"switchOnDurationMs":100}"#.utf8) // leftovers of a longer reply
        bytes += [UInt8](repeating: 0, count: 512 - bytes.count)

        let packet = try #require(ElgatoHID.parse(report: Data(bytes)))
        #expect(packet.kind == ElgatoHID.Kind.response.rawValue)
        #expect(packet.payload == Data(json.utf8))

        let decoded = ElgatoInbound.decode(kind: packet.kind, message: packet.payload)
        #expect(decoded == .lights(ElgatoLights(lights: [ElgatoLightState(on: 0, brightness: 30, temperature: 143)])))
    }

    @Test func notificationRepeatsRequestLine() {
        let message = Data(#"GET /elgato/lights {"numberOfLights":1,"lights":[{"on":1,"brightness":30,"temperature":143}]}"#.utf8)
        let decoded = ElgatoInbound.decode(kind: ElgatoHID.Kind.notification.rawValue, message: message)
        #expect(decoded == .lights(ElgatoLights(lights: [ElgatoLightState(on: 1, brightness: 30, temperature: 143)])))
    }

    @Test func accessoryInfoExposesPowerCap() throws {
        let json = #"{"productName":"Elgato Key Light Neo","hardwareBoardType":210,"firmwareVersion":"1.0.6","serialNumber":"AB8KB519119WIY","displayName":"","features":["lights","bt","hid"],"power-info":{"operationMode":1,"maximumBrightness":40}}"#
        guard case .accessoryInfo(let info) = ElgatoInbound.decode(kind: 0, message: Data(json.utf8)) else {
            Issue.record("expected accessory info")
            return
        }
        #expect(info.productName == "Elgato Key Light Neo")
        #expect(info.serialNumber == "AB8KB519119WIY")
        #expect(info.powerInfo?.maximumBrightness == 40)
    }

    @Test func rejectedRequestDecodesAsError() {
        let json = #"{"errors":[{"message":"Invalid parameters","code":-1}]}"#
        #expect(ElgatoInbound.decode(kind: 0, message: Data(json.utf8)) == .error("Invalid parameters"))
    }

    @Test func unrelatedBodiesAreUnknown() {
        let settings = #"{"powerOnBehavior":1,"powerOnBrightness":20,"powerOnTemperature":230}"#
        #expect(ElgatoInbound.decode(kind: 0, message: Data(settings.utf8)) == .unknown)
        #expect(ElgatoInbound.decode(kind: ElgatoHID.Kind.notification.rawValue, message: Data("garbage".utf8)) == .unknown)
    }

    @Test func rejectsMalformedReports() {
        #expect(ElgatoHID.parse(report: Data([0x01, 0x00, 0x01, 0x00, 0x00, 0x00])) == nil) // wrong report ID
        #expect(ElgatoHID.parse(report: Data([0x02, 0x01, 0x01, 0x00, 0x00, 0x00])) == nil) // index >= count
        #expect(ElgatoHID.parse(report: Data([0x02, 0x00, 0x01, 0x00, 0xFF, 0x00])) == nil) // length overflow
    }

    @Test func longMessagesRoundTripThroughReassembler() throws {
        let message = Data((0..<1200).map { UInt8(truncatingIfNeeded: $0) })
        let reports = ElgatoHID.reports(for: message)
        #expect(reports.count == 3)

        var reassembler = ElgatoHIDReassembler()
        var result: (kind: UInt8, message: Data)?
        for report in reports {
            let packet = try #require(ElgatoHID.parse(report: report))
            result = reassembler.consume(packet)
        }
        #expect(result?.kind == ElgatoHID.Kind.request.rawValue)
        #expect(result?.message == message)
    }

    @Test func reassemblerDropsOutOfOrderPackets() {
        var reassembler = ElgatoHIDReassembler()
        let second = ElgatoHID.Packet(index: 1, count: 2, kind: 0, payload: Data([1]))
        #expect(reassembler.consume(second) == nil)

        let single = ElgatoHID.Packet(index: 0, count: 1, kind: 0, payload: Data([7]))
        #expect(reassembler.consume(single)?.message == Data([7]))
    }

    @Test(arguments: [(143, 7000), (344, 2900), (230, 4350)])
    func temperatureFromDevice(value: Int, kelvin: Int) {
        #expect(ElgatoTemperature.kelvin(fromDeviceValue: value) == kelvin)
    }

    @Test(arguments: [(7000, 143), (2900, 344), (4350, 230), (10000, 143), (1000, 344)])
    func temperatureToDevice(kelvin: Int, value: Int) {
        #expect(ElgatoTemperature.deviceValue(fromKelvin: kelvin) == value)
    }
}

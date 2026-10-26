import Foundation
import Testing
@testable import LightsKit

/// Replies are the exact datagrams sent by a Govee Lyra (H6072).
struct GoveeLANTests {
    @Test(arguments: [
        (GoveeLAN.Command.scan, #"{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}"#),
        (.status, #"{"msg":{"cmd":"devStatus","data":{}}}"#),
        (.power(true), #"{"msg":{"cmd":"turn","data":{"value":1}}}"#),
        (.power(false), #"{"msg":{"cmd":"turn","data":{"value":0}}}"#),
        (.brightness(42), #"{"msg":{"cmd":"brightness","data":{"value":42}}}"#),
        (.brightness(0), #"{"msg":{"cmd":"brightness","data":{"value":1}}}"#),
        (.color(RGB(r: 255, g: 0, b: 0)), #"{"msg":{"cmd":"colorwc","data":{"color":{"b":0,"g":0,"r":255},"colorTemInKelvin":0}}}"#),
        (.colorTemperature(6500), #"{"msg":{"cmd":"colorwc","data":{"color":{"b":250,"g":254,"r":255},"colorTemInKelvin":6500}}}"#),
    ])
    func encodesCommand(command: GoveeLAN.Command, json: String) {
        #expect(String(decoding: GoveeLAN.encode(command), as: UTF8.self) == json)
    }

    @Test func decodesScanReply() {
        let reply = #"{"msg":{"cmd":"scan","data":{"ip":"192.168.68.51","device":"F2:65:D7:39:32:37:16:1C","sku":"H6072","bleVersionHard":"3.02.00","bleVersionSoft":"2.04.10","wifiVersionHard":"1.00.10","wifiVersionSoft":"1.02.11"}}}"#
        #expect(GoveeLAN.decode(Data(reply.utf8)) == .scan(GoveeDevice(ip: "192.168.68.51", device: "F2:65:D7:39:32:37:16:1C", sku: "H6072")))
    }

    @Test func decodesStatusReply() {
        let reply = #"{"msg":{"cmd":"devStatus","data":{"onOff":0,"brightness":27,"color":{"r":255,"g":255,"b":255},"colorTemInKelvin":4800}}}"#
        let expected = GoveeStatus(onOff: 0, brightness: 27, color: RGB(r: 255, g: 255, b: 255), colorTemInKelvin: 4800)
        #expect(GoveeLAN.decode(Data(reply.utf8)) == .status(expected))
    }

    @Test func ignoresUnknownMessages() {
        #expect(GoveeLAN.decode(Data(#"{"msg":{"cmd":"turn","data":{"value":1}}}"#.utf8)) == nil)
        #expect(GoveeLAN.decode(Data("not json".utf8)) == nil)
    }
}

struct RGBTests {
    @Test func huesMapToPrimaries() {
        #expect(RGB(hue: 0) == RGB(r: 255, g: 0, b: 0))
        #expect(RGB(hue: 1.0 / 3) == RGB(r: 0, g: 255, b: 0))
        #expect(RGB(hue: 2.0 / 3) == RGB(r: 0, g: 0, b: 255))
        #expect(RGB(hue: 1) == RGB(r: 255, g: 0, b: 0))
    }

    @Test func kelvinRunsFromAmberToBlueWhite() {
        let warm = RGB(kelvin: 2200), cool = RGB(kelvin: 9000)
        #expect(warm.r == 255 && warm.b < 60)
        #expect(cool.b == 255 && cool.r < 230)
    }

    @Test func componentsAreClamped() {
        #expect(RGB(r: -4, g: 300, b: 12) == RGB(r: 0, g: 255, b: 12))
    }
}

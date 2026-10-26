import Foundation
import Testing
@testable import LightsKit

struct NanoleafTests {
    @Test(arguments: [
        (Nanoleaf.Command.power(true), "state", #"{"on":{"value":true}}"#),
        (.brightness(42), "state", #"{"brightness":{"duration":0,"value":42}}"#),
        (.brightness(140), "state", #"{"brightness":{"duration":0,"value":100}}"#),
        (.color(RGB(r: 0, g: 0, b: 255)), "state", #"{"hue":{"value":240},"sat":{"value":100}}"#),
        (.colorTemperature(2700), "state", #"{"ct":{"value":2700}}"#),
        (.effect("Northern Lights"), "effects", #"{"select":"Northern Lights"}"#),
        (.requestAllEffects, "effects", #"{"write":{"command":"requestAll"}}"#),
    ])
    func encodesCommand(command: Nanoleaf.Command, path: String, json: String) throws {
        let request = Nanoleaf.request(for: command)
        #expect(request.method == "PUT")
        #expect(request.path == path)
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == json)
    }

    @Test func decodesDeviceInfo() throws {
        // As sent by a Secretlab MAGRGB XL (NL72S2, firmware 4.0.0), which has no "effects" block.
        let json = #"""
        {"name":"Secretlab MAGRGB 6B4","serialNo":"G26110ND00493","manufacturer":"Nanoleaf","firmwareVersion":"4.0.0",
         "hardwareVersion":"1.3.0","model":"NL72S2","state":{"on":{"value":true},"brightness":{"value":100,"max":100,"min":1},
         "hue":{"value":0,"max":360,"min":0},"sat":{"value":100,"max":100,"min":0},"ct":{"value":2702,"max":6535,"min":2127},
         "colorMode":"effect"}}
        """#
        let device = try JSONDecoder().decode(Nanoleaf.Device.self, from: Data(json.utf8))
        #expect(device.model == "NL72S2" && device.firmwareVersion == "4.0.0")
        #expect(device.state.on.value)
        #expect(device.state.brightness.value == 100 && device.state.brightness.min == 1)
        #expect(device.state.ct.min == 2127 && device.state.ct.max == 6535)
        #expect(device.state.colorMode == "effect")
        #expect(device.effects == nil)
    }

    @Test func decodesPanelEffects() throws {
        let json = #"{"name":"Shapes","state":{"on":{"value":false},"brightness":{"value":5},"hue":{"value":0},"sat":{"value":0},"ct":{"value":4000},"colorMode":"hs"},"effects":{"effectsList":["Fireplace","*Solid*"],"select":"*Solid*"}}"#
        let device = try JSONDecoder().decode(Nanoleaf.Device.self, from: Data(json.utf8))
        #expect(device.effects?.select == "*Solid*")
        #expect(device.effects?.effectsList?.filter(Nanoleaf.isScene) == ["Fireplace"])
    }

    @Test func decodesEffectPalettes() throws {
        let json = #"""
        {"animations":[
          {"animName":"Fireplace","animType":"wheel","palette":[{"hue":20,"saturation":100,"brightness":100}]},
          {"animName":"Cloud9","animType":"plugin","pluginType":"color","hexPalette":["D8FFF8","11A0FF"],"pluginOptions":[]},
          {"animName":"Volume Up","animType":"plugin","pluginType":"rhythm","hexPalette":["FF00DD","nonsense"]}
        ]}
        """#
        let animations = try JSONDecoder().decode(Nanoleaf.Animations.self, from: Data(json.utf8)).animations
        #expect(animations[0].colors == [RGB(r: 255, g: 85, b: 0)])
        #expect(animations[1].colors == [RGB(r: 0xD8, g: 0xFF, b: 0xF8), RGB(r: 0x11, g: 0xA0, b: 0xFF)])
        #expect(animations[2].pluginType == "rhythm" && animations[2].colors == [RGB(r: 255, g: 0, b: 0xDD)])
    }

    @Test func readsPairingToken() {
        #expect(Nanoleaf.token(fromPairingResponse: Data(#"{"auth_token":"abc123"}"#.utf8)) == "abc123")
        #expect(Nanoleaf.token(fromPairingResponse: Data("{}".utf8)) == nil)
    }

    @Test func colourRoundTripsThroughHueAndSaturation() {
        for color in [RGB(r: 255, g: 0, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 30, g: 100, b: 255), RGB(r: 255, g: 60, b: 170)] {
            let (hue, saturation) = color.hueSaturation
            let back = RGB(hue: Double(hue) / 360, saturation: Double(saturation) / 100)
            #expect(abs(back.r - color.r) <= 3 && abs(back.g - color.g) <= 3 && abs(back.b - color.b) <= 3)
        }
        let white = RGB(r: 255, g: 255, b: 255).hueSaturation
        #expect(white.hue == 0 && white.saturation == 0)
    }
}

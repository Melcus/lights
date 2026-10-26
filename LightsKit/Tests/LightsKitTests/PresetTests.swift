import Foundation
import Testing
@testable import LightsKit

struct PresetTests {
    private typealias Look = Preset.Look

    // The office: a Key Light Neo held to 40% by its USB power, a Govee Lyra and a Nanoleaf strip.
    private let keyLight = LightState(
        id: "key", isOn: false, brightness: 20, kelvin: 4000, brightnessRange: 3...100, brightnessLimit: 40, kelvinRange: 2900...7000
    )
    private let lyra = LightState(id: "lyra", isOn: true, brightness: 50, kelvin: 4000, kelvinRange: 2200...6500, supportsColor: true)
    private let strip = LightState(
        id: "strip", isOn: true, brightness: 64, kelvin: 3000, scene: "Northern Lights", kelvinRange: 1200...6500,
        supportsColor: true, scenes: ["Northern Lights", "Volume Up"]
    )

    @Test func builtInPresetsSuitWhateverLightsThereAre() throws {
        let call = try #require(Preset.builtIn.first { $0.name == "Call" })
        #expect(call.look(for: keyLight) == .white(brightness: 60, kelvin: 5000))
        #expect(call.look(for: lyra) == .white(brightness: 30, kelvin: 3000))
        #expect(call.look(for: strip) == .white(brightness: 30, kelvin: 3000))
        #expect(Set(Preset.builtIn.map(\.id)).count == Preset.builtIn.count)
    }

    @Test func stepsSwitchOnAndFitTheLight() throws {
        let call = try #require(Preset.builtIn.first { $0.name == "Call" })
        // 60% is more than the Key Light's power allows.
        #expect(call.steps(for: keyLight) == [.power(true), .kelvin(5000), .brightness(40)])

        let warm = Preset(name: "Warm", symbol: "flame.fill", whiteLights: .white(brightness: 50, kelvin: 2700))
        var on = keyLight
        on.isOn = true
        #expect(warm.steps(for: on) == [.kelvin(2900), .brightness(40)])
    }

    @Test func offOnlySwitchesOffLightsThatAreOn() {
        let dark = Preset(name: "Dark", symbol: "moon.fill", whiteLights: .off, colorLights: .off)
        #expect(dark.steps(for: lyra) == [.power(false)])
        #expect(dark.steps(for: keyLight).isEmpty)
    }

    @Test func leavesOutWhatALightCannotShow() {
        let colour = Preset(name: "Pink", symbol: "heart.fill", lights: ["key": .color(brightness: 30, rgb: RGB(r: 255, g: 60, b: 170))])
        #expect(colour.steps(for: keyLight) == [.power(true), .brightness(30)])

        let missing = Preset(name: "Gone", symbol: "star.fill", lights: ["strip": .scene(brightness: 50, name: "Deleted Scene")])
        #expect(missing.steps(for: strip) == [.brightness(50)])
        var unlisted = strip
        unlisted.scenes = [] // not reported yet
        #expect(missing.steps(for: unlisted) == [.scene("Deleted Scene"), .brightness(50)])
    }

    @Test func lightsOutOfReachOrLeftOutGetNothing() {
        let preset = Preset(name: "Lamp", symbol: "lamp.floor.fill", lights: ["lyra": .white(brightness: 80, kelvin: 2700)])
        #expect(preset.steps(for: strip).isEmpty)
        var away = lyra
        away.isReachable = false
        #expect(preset.steps(for: away).isEmpty)
    }

    @Test func capturesWhatEachLightShows() {
        var red = lyra
        red.color = RGB(r: 255, g: 45, b: 35)
        var away = lyra
        away.id = "away"
        away.isReachable = false
        let preset = Preset(capturing: [keyLight, red, strip, away], name: "Mine", symbol: "star.fill")
        #expect(preset.lights == [
            "key": .off,
            "lyra": .color(brightness: 50, rgb: RGB(r: 255, g: 45, b: 35)),
            "strip": .scene(brightness: 64, name: "Northern Lights"),
        ])
        #expect(preset.whiteLights == nil && preset.colorLights == nil)
        #expect(preset.matches([keyLight, red, strip, away]))
    }

    @Test func matchesWithinTheRoundingLightsDo() {
        let preset = Preset(name: "Mixed", symbol: "star.fill", lights: [
            "key": .white(brightness: 60, kelvin: 4500),
            "lyra": .color(brightness: 50, rgb: RGB(r: 0, g: 200, b: 190)),
        ])
        // The Key Light stops at 40% and reports 4504 K; Nanoleaf-style colour comes back at full value.
        var key = keyLight
        (key.isOn, key.brightness, key.kelvin) = (true, 40, 4504)
        var teal = lyra
        teal.color = RGB(hue: 177.0 / 360, saturation: 1)
        #expect(preset.matches([key, teal, strip]))

        var dimmer = key
        dimmer.brightness = 35
        #expect(!preset.matches([dimmer, teal]))
        var green = teal
        green.color = RGB(r: 40, g: 215, b: 80)
        #expect(!preset.matches([key, green]))
        var scene = key
        scene.scene = "Northern Lights"
        #expect(!preset.matches([scene, teal]))

        // Out of reach doesn't count against it, but something must be showing it.
        var away = teal
        away.isReachable = false
        #expect(preset.matches([key, away]))
        var keyAway = key
        keyAway.isReachable = false
        #expect(!preset.matches([keyAway, away]))
    }

    @Test func presetsOnePercentApartAreToldApart() {
        let dim = Preset(capturing: [lyra], name: "Dim", symbol: "moon.fill")
        var brighter = lyra
        brighter.brightness += 1
        let bright = Preset(capturing: [brighter], name: "Bright", symbol: "sun.max.fill")
        #expect(dim.matches([lyra]) && !bright.matches([lyra]))
        #expect(bright.matches([brighter]) && !dim.matches([brighter]))
    }

    @Test func givingOneLightItsOwnLookKeepsTheOthers() throws {
        var call = try #require(Preset.builtIn.first { $0.name == "Call" })
        call.setLook(nil, forLight: "lyra", among: [keyLight, lyra, strip])
        #expect(call.lights == ["key": .white(brightness: 60, kelvin: 5000), "strip": .white(brightness: 30, kelvin: 3000)])
        #expect(call.look(for: lyra) == nil)

        call.setLook(.off, forLight: "lyra", among: [keyLight, lyra, strip])
        #expect(call.look(for: lyra) == .off)
        #expect(call.whiteLights == nil && call.colorLights == nil)
    }

    @Test func keepsItsSavedForm() throws {
        let saved = """
        [{"id":"6E1F1C2A-37B4-4F0E-9C51-0A11CE000003","name":"Relax","symbol":"sofa.fill","lights":{},\
        "whiteLights":{"off":{}},"colorLights":{"white":{"brightness":35,"kelvin":2700}}},\
        {"id":"0B5F6D7E-1111-4222-8333-944455556666","name":"Mine","symbol":"star.fill","lights":{\
        "lyra":{"color":{"brightness":50,"rgb":{"r":255,"g":45,"b":35}}},"strip":{"scene":{"brightness":64,"name":"Northern Lights"}}}}]
        """
        let presets = try JSONDecoder().decode([Preset].self, from: Data(saved.utf8))
        #expect(presets[0] == Preset.builtIn[2])
        #expect(presets[1].lights["strip"] == .scene(brightness: 64, name: "Northern Lights"))
        let roundTrip = try JSONDecoder().decode([Preset].self, from: JSONEncoder().encode(presets))
        #expect(roundTrip == presets)
    }
}

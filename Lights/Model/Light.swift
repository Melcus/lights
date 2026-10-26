import Foundation
import LightsKit
import Observation

/// Implemented by the transports (USB HID, Govee LAN, Nanoleaf HTTP) that own a light's connection.
protocol LightController: AnyObject {
    func send(_ change: LightChange, to light: Light)
    func refresh(_ light: Light)
    /// Lights that need a token (Nanoleaf) start pairing; others ignore it.
    func pair(_ light: Light)
    func cancelPairing(_ light: Light)
}

extension LightController {
    func pair(_ light: Light) {}
    func cancelPairing(_ light: Light) {}
}

enum LightChange: Equatable {
    case power(Bool)
    case brightness(Int)
    case kelvin(Int)
    case color(RGB)
    case effect(String)
}

@Observable
final class Light: Identifiable {
    enum Kind: Int, Comparable {
        case keyLight, govee, nanoleaf

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Capabilities: Equatable {
        var brightnessRange: ClosedRange<Int>
        var kelvinRange: ClosedRange<Int>
        var supportsColor: Bool
    }

    enum Availability {
        case connecting, online, offline
    }

    enum Pairing: Equatable {
        /// Found, but without the token the device hands out in pairing mode.
        case needed
        /// Asking for a token every couple of seconds until the device's pairing window opens.
        case waiting
    }

    /// A scene the device can play, with colours for a preview.
    struct Effect: Identifiable, Equatable {
        let name: String
        var palette: [RGB]
        /// Reacts to sound.
        var isRhythm = false

        var id: String { name }
    }

    /// What a device report says about colour.
    enum ReportedColor {
        case unchanged
        case white(kelvin: Int)
        case rgb(RGB)
        case effect(String)
    }

    let id: String
    let kind: Kind
    /// Network lights only report their ranges once connected.
    var capabilities: Capabilities
    var defaultName: String
    var customName: String?
    var model: String
    var firmwareVersion: String?
    var connectionDetail = ""
    var availability = Availability.connecting
    /// Why the light is offline, when the transport knows (shown instead of "Not responding").
    var offlineReason: String?
    var isOn = false
    var brightness: Int
    var kelvin: Int
    /// Set while the light shows an RGB colour rather than white.
    var color: RGB?
    /// Set while the light plays a scene.
    var effect: String?
    /// Scenes the light can play, if it has any.
    var effects: [Effect] = []
    var pairing: Pairing?
    /// Cap imposed by the device itself, e.g. a Key Light Neo on weak USB power.
    var maxBrightness: Int?

    @ObservationIgnored weak var controller: (any LightController)?
    @ObservationIgnored private var lastLocalEdit = ContinuousClock.now - .seconds(60)

    init(id: String, kind: Kind, defaultName: String, model: String, capabilities: Capabilities) {
        self.id = id
        self.kind = kind
        self.defaultName = defaultName
        self.model = model
        self.capabilities = capabilities
        brightness = capabilities.brightnessRange.upperBound / 2
        kelvin = (capabilities.kelvinRange.lowerBound + capabilities.kelvinRange.upperBound) / 2
    }

    /// `customName` keeps what the user typed, spaces included; display trims it.
    var name: String {
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    var isReachable: Bool { availability == .online }

    /// Short state for when the light can't be controlled, e.g. "Not responding".
    var availabilityText: String? {
        switch pairing {
        case .needed: return "Not paired"
        case .waiting: return "Waiting to pair…"
        case nil: break
        }
        return switch availability {
        case .connecting: "Connecting…"
        case .offline: offlineReason ?? "Not responding"
        case .online: nil
        }
    }

    var brightnessLimit: Int { min(maxBrightness ?? .max, capabilities.brightnessRange.upperBound) }

    /// Colour the light is emitting.
    var emittedColor: RGB { color ?? RGB(kelvin: kelvin) }

    /// Colours of the scene playing, if the light reported them.
    var effectPalette: [RGB]? {
        effect.flatMap { name in effects.first { $0.name == name }?.palette }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Called for every user edit so reports already in flight don't snap a slider back mid-drag.
    func noteLocalEdit() {
        lastLocalEdit = .now
    }

    func applyReported(isOn: Bool?, brightness: Int?, color reported: ReportedColor) {
        update(\.availability, .online)
        guard ContinuousClock.now - lastLocalEdit > .milliseconds(1500) else { return }

        if let isOn { update(\.isOn, isOn) }
        if let brightness { update(\.brightness, brightness) }
        switch reported {
        case .unchanged:
            break
        case .white(let kelvin):
            update(\.kelvin, kelvin)
            update(\.color, nil)
            update(\.effect, nil)
        case .rgb(let rgb):
            update(\.color, rgb)
            update(\.effect, nil)
        case .effect(let name):
            update(\.effect, name)
            update(\.color, nil)
        }
    }

    /// Devices repeat their state every second or so; only real changes should invalidate views.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Light, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

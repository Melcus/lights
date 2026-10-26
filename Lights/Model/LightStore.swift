import Foundation
import LightsKit
import Observation

/// Owns every known light and applies user actions optimistically before the device confirms.
@Observable
final class LightStore {
    private(set) var lights: [Light] = []

    @ObservationIgnored private lazy var keyLights = ElgatoUSBService(store: self)
    @ObservationIgnored private lazy var govee = GoveeLANService(store: self)
    @ObservationIgnored private lazy var nanoleaf = NanoleafService(store: self)
    @ObservationIgnored private var throttles: [String: Throttle] = [:]
    @ObservationIgnored private var settleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var customNames: [String: String]
    /// Told about brightness and colour changes made by hand, so adaptive lighting can step aside.
    @ObservationIgnored var onManualChange: ((Light) -> Void)?

    private static let namesKey = "lightNames"

    init() {
        customNames = UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }

    var reachableLights: [Light] { lights.filter(\.isReachable) }
    var anyOn: Bool { reachableLights.contains(where: \.isOn) }

    func start() {
        keyLights.start()
        govee.start()
        nanoleaf.start()
    }

    func light(id: String) -> Light? { lights.first { $0.id == id } }

    // MARK: Registration (called by transports)

    func add(_ light: Light) {
        guard self.light(id: light.id) == nil else { return }
        light.customName = customNames[light.id]
        lights.append(light)
        lights.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    func remove(_ light: Light) {
        lights.removeAll { $0 === light }
    }

    // MARK: Actions

    func toggle(_ light: Light) {
        setPower(!light.isOn, for: light)
    }

    func setPower(_ on: Bool, for light: Light) {
        guard light.isReachable else { return }
        light.noteLocalEdit()
        light.isOn = on
        light.controller?.send(.power(on), to: light)
        settle(light)
    }

    func setBrightness(_ value: Int, for light: Light) {
        guard light.isReachable else { return }
        let range = light.capabilities.brightnessRange
        let brightness = min(max(value, range.lowerBound), light.brightnessLimit)
        if !light.isOn { setPower(true, for: light) }
        light.noteLocalEdit()
        light.brightness = brightness
        throttle(light, "brightness") { light.controller?.send(.brightness(brightness), to: light) }
        settle(light)
        onManualChange?(light)
    }

    func setKelvin(_ value: Int, for light: Light) {
        guard light.isReachable else { return }
        let range = light.capabilities.kelvinRange
        let kelvin = min(max(value, range.lowerBound), range.upperBound)
        if !light.isOn { setPower(true, for: light) }
        light.noteLocalEdit()
        light.kelvin = kelvin
        light.color = nil
        light.effect = nil
        throttle(light, "color") { light.controller?.send(.kelvin(kelvin), to: light) }
        settle(light)
        onManualChange?(light)
    }

    func setColor(_ color: RGB, for light: Light) {
        guard light.isReachable, light.capabilities.supportsColor else { return }
        if !light.isOn { setPower(true, for: light) }
        light.noteLocalEdit()
        light.color = color
        light.effect = nil
        throttle(light, "color") { light.controller?.send(.color(color), to: light) }
        settle(light)
        onManualChange?(light)
    }

    func setEffect(_ name: String, for light: Light) {
        guard light.isReachable else { return }
        if !light.isOn { setPower(true, for: light) }
        light.noteLocalEdit()
        light.effect = name
        light.color = nil
        throttle(light, "color") { light.controller?.send(.effect(name), to: light) }
        settle(light)
        onManualChange?(light)
    }

    /// Adaptive lighting: sets white and, when given, brightness. Unlike the setters above it never
    /// switches a light on and doesn't count as a manual change.
    func applyAdaptive(kelvin: Int, brightness: Int?, to light: Light) {
        guard light.isReachable, light.isOn else { return }
        light.noteLocalEdit()
        light.kelvin = kelvin
        light.color = nil
        light.effect = nil
        throttle(light, "color") { light.controller?.send(.kelvin(kelvin), to: light) }
        if let brightness {
            light.brightness = brightness
            throttle(light, "brightness") { light.controller?.send(.brightness(brightness), to: light) }
        }
        settle(light) // read it back promptly so adaptive lighting can confirm the light took it
    }

    /// Turns everything off when anything is on, like a room switch.
    func toggleAll() {
        setAll(on: !anyOn)
    }

    func setAll(on: Bool) {
        for light in reachableLights { setPower(on, for: light) }
    }

    func adjustBrightness(by delta: Int) {
        for light in reachableLights where light.isOn {
            setBrightness(light.brightness + delta, for: light)
        }
    }

    func refreshAll() {
        for light in lights { light.controller?.refresh(light) }
    }

    #if DEBUG
    func simulateStuckGoveeSocket() {
        govee.simulateStuckSocket()
    }

    func adoptNanoleafToken(_ token: String, for light: Light) {
        nanoleaf.adoptToken(token, for: light)
    }
    #endif

    func searchAgain() {
        govee.discover()
        nanoleaf.discover()
        refreshAll()
    }

    func pair(_ light: Light) {
        light.controller?.pair(light)
    }

    func cancelPairing(_ light: Light) {
        light.controller?.cancelPairing(light)
    }

    /// Stores the text as typed; trimming on every keystroke would eat the space before a second word.
    func rename(_ light: Light, to name: String) {
        light.customName = name.isEmpty ? nil : name
        customNames[light.id] = light.customName
        UserDefaults.standard.set(customNames, forKey: Self.namesKey)
    }

    /// Drops a network light until it's discovered again; a Nanoleaf also loses its token.
    func forget(_ light: Light) {
        switch light.kind {
        case .govee: govee.forget(light)
        case .nanoleaf: nanoleaf.forget(light)
        case .keyLight: return
        }
        remove(light)
    }

    // MARK: Private

    /// USB writes are cheap; Wi-Fi controllers drop or queue commands when flooded.
    private func throttle(_ light: Light, _ property: String, _ action: @escaping () -> Void) {
        let key = "\(light.id).\(property)"
        let interval: Duration = switch light.kind {
        case .keyLight: .milliseconds(40)
        case .govee: .milliseconds(120)
        case .nanoleaf: .milliseconds(100)
        }
        let throttle = throttles[key] ?? Throttle(interval: interval)
        throttles[key] = throttle
        throttle.run(action)
    }

    /// Re-reads the device once edits stop, catching anything it rejected or clamped.
    private func settle(_ light: Light) {
        settleTasks[light.id]?.cancel()
        settleTasks[light.id] = Task { [weak light] in
            try? await Task.sleep(for: .milliseconds(1700))
            guard !Task.isCancelled, let light else { return }
            light.controller?.refresh(light)
        }
    }
}

import AppKit
import LightsKit
import Network
import os

/// Nanoleaf lights, the Secretlab MAGRGB included, through their local HTTP API.
///
/// Devices are found over Bonjour and remembered with their address, so they appear at launch and
/// keep working on networks that drop multicast. Each needs a token, handed out only while its
/// pairing window is open ("Connect to API" in the Nanoleaf app); tokens live in the keychain.
/// The MAGRGB has no event stream, so state is polled.
final class NanoleafService: LightController {
    private struct Address: Codable, Equatable {
        var host: String
        var port: Int
    }

    private final class Device {
        let id: String
        let light: Light
        let name: String
        let model: String?
        var address: Address?
        var token: String?
        var lastSeen: ContinuousClock.Instant?
        var lastResolve = ContinuousClock.now - .seconds(60)
        /// Commands waiting to go out, one request at a time so they arrive in order. A newer
        /// command for the same property replaces an older one still waiting.
        var outbox: [(property: String, command: Nanoleaf.Command)] = []
        var isSending = false
        var isPolling = false
        var scenesLoadedAt: ContinuousClock.Instant?
        var pairing: Task<Void, Never>?

        init(id: String, light: Light, name: String, model: String?, address: Address?, token: String?) {
            self.id = id
            self.light = light
            self.name = name
            self.model = model
            self.address = address
            self.token = token
        }
    }

    private struct KnownDevice: Codable {
        var id: String
        var name: String
        var model: String?
        var address: Address
    }

    private unowned let store: LightStore
    private var devices: [String: Device] = [:]           // keyed by EUI-64
    private var browser: NWBrowser?
    private var browseResults: [String: NWBrowser.Result] = [:]
    private var startedAt = ContinuousClock.now
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let session: URLSession
    private let log = Logger(subsystem: "ro.tirdea.Lights", category: "Nanoleaf")

    private static let knownDevicesKey = "nanoleafDevices"
    private static let keychainService = "ro.tirdea.Lights.nanoleaf"
    /// Long enough to click Pair, pick up the phone and find the setting.
    private static let pairingWindow: Duration = .seconds(120)

    init(store: LightStore) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func start() {
        startedAt = .now
        for known in knownDevices {
            register(id: known.id, name: known.name, model: known.model, address: known.address)
        }
        discover()
        pollAll()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
    }

    /// Starts browsing afresh, which reports every device on the network again.
    func discover() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Nanoleaf.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            MainActor.assumeIsolated {
                self?.log.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func forget(_ light: Light) {
        guard let device = device(for: light) else { return }
        device.pairing?.cancel()
        Keychain.deleteToken(service: Self.keychainService, account: device.id)
        devices[device.id] = nil
        saveKnownDevices(knownDevices.filter { $0.id != device.id })
    }

    // MARK: LightController

    func send(_ change: LightChange, to light: Light) {
        guard let device = device(for: light) else { return }
        // White, colour and scene replace each other, so only the newest of them matters.
        switch change {
        case .power(let on): enqueue(.power(on), property: "power", on: device)
        case .brightness(let value): enqueue(.brightness(value), property: "brightness", on: device)
        case .kelvin(let kelvin): enqueue(.colorTemperature(kelvin), property: "color", on: device)
        case .color(let color): enqueue(.color(color), property: "color", on: device)
        case .effect(let name): enqueue(.effect(name), property: "color", on: device)
        }
    }

    func refresh(_ light: Light) {
        device(for: light).map(poll)
    }

    func pair(_ light: Light) {
        guard let device = device(for: light), device.pairing == nil else { return }
        light.pairing = .waiting
        device.pairing = Task {
            let deadline = ContinuousClock.now + Self.pairingWindow
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let token = await requestToken(from: device) {
                    paired(device, token: token)
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return } // cancelPairing already tidied up
            device.pairing = nil
            if device.token == nil { light.pairing = .needed }
        }
    }

    func cancelPairing(_ light: Light) {
        guard let device = device(for: light), let pairing = device.pairing else { return }
        pairing.cancel()
        device.pairing = nil
        if device.token == nil { light.pairing = .needed }
    }

    #if DEBUG
    /// Adopts a token obtained outside the app, e.g. by a script polling during the pairing window.
    func adoptToken(_ token: String, for light: Light) {
        guard let device = device(for: light) else { return }
        paired(device, token: token)
    }
    #endif

    // MARK: Discovery

    private func found(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            // The EUI-64 survives a factory reset; "id" and the service name don't.
            let id = txt["eui64"] ?? txt["id"] ?? name
            browseResults[id] = result
            let device = register(id: id, name: name, model: txt["md"], address: nil)
            // A remembered address may be stale, so check it unless the device is answering.
            if device.address == nil || device.light.availability != .online {
                resolve(result, for: device)
            }
        }
    }

    /// Bonjour names a service; HTTP needs an address, which a TCP connection to it reveals.
    private func resolve(_ result: NWBrowser.Result, for device: Device) {
        device.lastResolve = .now
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: result.endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    if case .hostPort(.ipv4(let ip), let port)? = connection.currentPath?.remoteEndpoint {
                        self?.resolved(device, Address(host: ip.rawValue.map(String.init).joined(separator: "."), port: Int(port.rawValue)))
                    }
                    connection.cancel()
                case .waiting, .failed:
                    connection.cancel()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private func resolved(_ device: Device, _ address: Address) {
        guard device.address != address else { return }
        log.info("\(device.name, privacy: .public) is at \(address.host, privacy: .public)")
        device.address = address
        device.light.connectionDetail = "Wi-Fi · \(address.host)"
        remember(device)
        poll(device)
    }

    /// The address may have changed (DHCP); ask Bonjour again, at most twice a minute.
    private func resolveAgain(_ device: Device) {
        guard let result = browseResults[device.id], ContinuousClock.now - device.lastResolve > .seconds(30) else { return }
        resolve(result, for: device)
    }

    @discardableResult
    private func register(id: String, name: String, model: String?, address: Address?) -> Device {
        if let device = devices[id] { return device }
        let light = Light(
            id: "nanoleaf:\(id)",
            kind: .nanoleaf,
            defaultName: NanoleafCatalog.name(for: name),
            model: NanoleafCatalog.model(name: name, model: model),
            // Replaced by the device's own ranges on the first report.
            capabilities: .init(brightnessRange: 1...100, kelvinRange: 2700...6500, supportsColor: true)
        )
        light.controller = self
        let token = Keychain.token(service: Self.keychainService, account: id)
        if token == nil { light.pairing = .needed }
        if let address { light.connectionDetail = "Wi-Fi · \(address.host)" }
        let device = Device(id: id, light: light, name: name, model: model, address: address, token: token)
        devices[id] = device
        store.add(light)
        return device
    }

    // MARK: State

    private func pollAll() {
        let now = ContinuousClock.now
        for device in devices.values where device.token != nil {
            // Silent for three polls, or never answered since launch: show it as not responding.
            let silentFor = now - (device.lastSeen ?? startedAt)
            if device.light.availability != .offline, silentFor > .seconds(device.lastSeen == nil ? 15 : 35) {
                device.light.availability = .offline
            }
            poll(device)
        }
    }

    private func poll(_ device: Device) {
        guard device.token != nil, device.address != nil, !device.isPolling else { return }
        device.isPolling = true
        Task {
            defer { device.isPolling = false }
            guard let data = await call("GET", "", on: device),
                  let info = try? JSONDecoder().decode(Nanoleaf.Device.self, from: data) else { return }
            var scene = info.effects?.select
            if info.state.colorMode == "effect", scene == nil, let data = await call("GET", "effects/select", on: device) {
                scene = try? JSONDecoder().decode(String.self, from: data)
            }
            apply(info, scene: scene, to: device)

            let scenesAreStale = device.scenesLoadedAt.map { ContinuousClock.now - $0 > .seconds(600) } ?? true
            let sceneIsUnknown = scene.map { name in Nanoleaf.isScene(name) && !device.light.effects.contains { $0.name == name } } ?? false
            if scenesAreStale || sceneIsUnknown { await loadScenes(of: device) }
        }
    }

    private func apply(_ info: Nanoleaf.Device, scene: String?, to device: Device) {
        let light = device.light
        let state = info.state
        let lowestBrightness = max(state.brightness.min ?? 1, 1)
        let coolest = state.ct.max ?? 6500, warmest = min(state.ct.min ?? 1200, coolest)
        let capabilities = Light.Capabilities(
            brightnessRange: lowestBrightness...max(state.brightness.max ?? 100, lowestBrightness),
            kelvinRange: warmest...coolest,
            supportsColor: true
        )
        if light.capabilities != capabilities { light.capabilities = capabilities }
        if light.firmwareVersion != info.firmwareVersion { light.firmwareVersion = info.firmwareVersion }

        let reported: Light.ReportedColor
        switch state.colorMode {
        case "ct":
            reported = .white(kelvin: state.ct.value)
        case "hs":
            // Keep the exact colour picked here when the device reports it back in its coarser terms
            // (the MAGRGB stores 29° as 28°).
            let hueSaturation = (hue: state.hue.value, saturation: state.sat.value)
            if let current = light.color, Self.isClose(current.hueSaturation, hueSaturation) {
                reported = .rgb(current)
            } else {
                reported = .rgb(RGB(hue: Double(hueSaturation.hue) / 360, saturation: Double(hueSaturation.saturation) / 100))
            }
        default:
            reported = scene.flatMap { Nanoleaf.isScene($0) ? .effect($0) : nil } ?? .unchanged
        }
        light.applyReported(isOn: state.on.value, brightness: state.brightness.value, color: reported)
    }

    private static func isClose(_ a: (hue: Int, saturation: Int), _ b: (hue: Int, saturation: Int)) -> Bool {
        let hueDistance = abs(a.hue - b.hue) % 360
        return min(hueDistance, 360 - hueDistance) <= 2 && abs(a.saturation - b.saturation) <= 2
    }

    /// Scene names, plus their colours for the previews.
    private func loadScenes(of device: Device) async {
        guard let data = await call("GET", "effects/effectsList", on: device),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return }
        let request = Nanoleaf.request(for: .requestAllEffects)
        let animations = await call(request.method, request.path, body: request.body, on: device)
            .flatMap { try? JSONDecoder().decode(Nanoleaf.Animations.self, from: $0) }?.animations ?? []
        let details = Dictionary(animations.map { ($0.animName, $0) }, uniquingKeysWith: { first, _ in first })
        let effects = names.filter(Nanoleaf.isScene).map { name in
            Light.Effect(name: name, palette: details[name]?.colors ?? [], isRhythm: details[name]?.pluginType == "rhythm")
        }
        if device.light.effects != effects { device.light.effects = effects }
        device.scenesLoadedAt = .now
    }

    // MARK: Requests

    private func enqueue(_ command: Nanoleaf.Command, property: String, on device: Device) {
        device.outbox.removeAll { $0.property == property }
        device.outbox.append((property, command))
        sendNext(on: device)
    }

    private func sendNext(on device: Device) {
        guard !device.isSending, !device.outbox.isEmpty else { return }
        let request = Nanoleaf.request(for: device.outbox.removeFirst().command)
        device.isSending = true
        Task {
            _ = await call(request.method, request.path, body: request.body, on: device)
            device.isSending = false
            sendNext(on: device)
        }
    }

    /// Returns the body of a successful response. `path` is relative to `/api/v1/<token>/`.
    private func call(_ method: String, _ path: String, body: Data? = nil, on device: Device) async -> Data? {
        guard let token = device.token, let address = device.address,
              let url = URL(string: "http://\(address.host):\(address.port)/api/v1/\(token)/\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            device.lastSeen = .now
            if status == 401 {
                tokenRejected(device)
                return nil
            }
            guard (200..<300).contains(status) else {
                log.debug("\(method, privacy: .public) \(path, privacy: .public) answered \(status)")
                return nil
            }
            return data
        } catch {
            if !(error is CancellationError) { resolveAgain(device) }
            return nil
        }
    }

    private func requestToken(from device: Device) async -> String? {
        guard let address = device.address, let url = URL(string: "http://\(address.host):\(address.port)/api/v1/new") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 403 until the pairing window opens.
        guard let result = try? await session.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Nanoleaf.token(fromPairingResponse: result.0)
    }

    private func paired(_ device: Device, token: String) {
        log.notice("Paired with \(device.name, privacy: .public)")
        if !Keychain.setToken(token, service: Self.keychainService, account: device.id, label: "Lights: \(device.name)") {
            log.error("Couldn't store the token for \(device.name, privacy: .public) in the keychain")
        }
        device.token = token
        device.scenesLoadedAt = nil
        device.light.pairing = nil
        poll(device)
    }

    /// The device no longer knows the token, typically after a factory reset.
    private func tokenRejected(_ device: Device) {
        guard device.token != nil else { return }
        log.notice("\(device.name, privacy: .public) rejected its token; it needs pairing again")
        Keychain.deleteToken(service: Self.keychainService, account: device.id)
        device.token = nil
        device.outbox = []
        device.light.pairing = .needed
        device.light.availability = .connecting
    }

    private func device(for light: Light) -> Device? {
        devices.values.first { $0.light === light }
    }

    // MARK: Known devices

    private var knownDevices: [KnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.knownDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([KnownDevice].self, from: data)) ?? []
    }

    private func remember(_ device: Device) {
        guard let address = device.address else { return }
        let known = KnownDevice(id: device.id, name: device.name, model: device.model, address: address)
        saveKnownDevices(knownDevices.filter { $0.id != device.id } + [known])
    }

    private func saveKnownDevices(_ devices: [KnownDevice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.knownDevicesKey)
    }
}

/// Friendlier names for what the strip calls itself.
enum NanoleafCatalog {
    /// "Secretlab MAGRGB 6B4" → "MAGRGB".
    static func name(for serviceName: String) -> String {
        serviceName.hasPrefix("Secretlab MAGRGB") ? "MAGRGB" : serviceName
    }

    static func model(name: String, model: String?) -> String {
        let base = name.hasPrefix("Secretlab MAGRGB") ? "Secretlab MAGRGB" : "Nanoleaf"
        return model.map { "\(base) (\($0))" } ?? base
    }
}

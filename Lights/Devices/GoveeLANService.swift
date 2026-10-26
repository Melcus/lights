import AppKit
import Darwin
import LightsKit
import Network
import os

/// Govee lights on the local network, via the LAN API ("LAN Control" must be on in Govee Home).
///
/// Devices answer on UDP 4002 of the sender's address, so a single socket bound to that port
/// sends everything and receives every reply. Commands are not acknowledged; state comes from
/// polling `devStatus`.
final class GoveeLANService: LightController {
    private unowned let store: LightStore
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var lights: [String: Light] = [:]         // keyed by Govee device ID
    private var addresses: [String: String] = [:]     // device ID → IP
    private var lastSeen: [String: ContinuousClock.Instant] = [:]
    private var startedAt = ContinuousClock.now
    private var lastSocketReset = ContinuousClock.now
    private var timers: [Timer] = []
    private let pathMonitor = NWPathMonitor()
    private var hasSeenInitialPath = false
    private var wakeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "ro.tirdea.Lights", category: "Govee")

    private static let knownDevicesKey = "goveeDevices"

    init(store: LightStore) {
        self.store = store
    }

    func start() {
        startedAt = .now
        openSocket()
        // Known devices show up immediately and are polled directly, so multicast-unfriendly
        // networks only matter for first discovery.
        for device in knownDevices { register(device) }
        discover()
        pollStatus()
        schedule(every: 30) { $0.discover() }
        schedule(every: 10) { $0.pollStatus() }

        // Wi-Fi roaming, docking, VPNs and sleep can leave the socket unable to send; start afresh.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkChanged(isUsable: path.status == .satisfied) }
        }
        pathMonitor.start(queue: .main)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkChanged(isUsable: true) }
        }
    }

    func discover() {
        send(.scan, to: GoveeLAN.multicastAddress, port: GoveeLAN.scanPort)
    }

    // MARK: LightController

    func send(_ change: LightChange, to light: Light) {
        guard let ip = address(of: light) else { return }
        let command: GoveeLAN.Command? = switch change {
        case .power(let on): .power(on)
        case .brightness(let value): .brightness(value)
        case .kelvin(let kelvin): .colorTemperature(kelvin)
        case .color(let color): .color(color)
        case .effect: nil
        }
        if let command { send(command, to: ip, port: GoveeLAN.commandPort) }
    }

    func refresh(_ light: Light) {
        guard let ip = address(of: light) else { return }
        send(.status, to: ip, port: GoveeLAN.commandPort)
    }

    // MARK: Devices

    private func register(_ device: GoveeDevice) {
        // A scan reply is authoritative for its address. Status replies are matched by address, so a
        // stale mapping (a replaced lamp, or two lamps that swapped IPs) must not keep claiming it.
        for (id, ip) in addresses where ip == device.ip && id != device.device {
            addresses[id] = nil
        }
        addresses[device.device] = device.ip
        if let light = lights[device.device] {
            light.connectionDetail = "Wi-Fi · \(device.ip)"
            return
        }

        let light = Light(
            id: "govee:\(device.device)",
            kind: .govee,
            defaultName: GoveeCatalog.name(for: device.sku),
            model: "Govee \(device.sku)",
            capabilities: GoveeCatalog.capabilities(for: device.sku)
        )
        light.connectionDetail = "Wi-Fi · \(device.ip)"
        light.controller = self
        lights[device.device] = light
        store.add(light)
    }

    private func handle(_ data: Data, from ip: String) {
        switch GoveeLAN.decode(data) {
        case .scan(let device):
            let isNew = lights[device.device] == nil
            register(device)
            lights[device.device]?.offlineReason = nil
            remember(device)
            if isNew { log.info("Discovered \(device.sku, privacy: .public) at \(device.ip, privacy: .public)") }
            lastSeen[device.device] = .now
            send(.status, to: device.ip, port: GoveeLAN.commandPort)

        case .status(let status):
            guard let id = addresses.first(where: { $0.value == ip })?.key, let light = lights[id] else { return }
            lastSeen[id] = .now
            light.offlineReason = nil
            light.applyReported(
                isOn: status.onOff == 1,
                brightness: status.brightness,
                color: status.colorTemInKelvin > 0 ? .white(kelvin: status.colorTemInKelvin) : .rgb(status.color)
            )

        case nil:
            break
        }
    }

    private func pollStatus() {
        let now = ContinuousClock.now
        for (id, light) in lights {
            // Silent for three polls, or never answered since launch: show it as not responding.
            let silentFor = now - (lastSeen[id] ?? startedAt)
            if light.availability != .offline, silentFor > .seconds(lastSeen[id] == nil ? 12 : 35) {
                light.availability = .offline
            }
            if let ip = addresses[id] { send(.status, to: ip, port: GoveeLAN.commandPort) }
        }

        // Not a word from any lamp for a minute: the socket may be stuck without reporting errors,
        // and a fresh one costs nothing.
        if !lights.isEmpty, lights.keys.allSatisfy({ now - (lastSeen[$0] ?? startedAt) > .seconds(60) }) {
            _ = recreateSocket(minimumInterval: .seconds(60))
        }
    }

    private func networkChanged(isUsable: Bool) {
        guard hasSeenInitialPath else {
            hasSeenInitialPath = true // the monitor reports the current path once at start
            return
        }
        guard isUsable else { return }
        _ = recreateSocket(minimumInterval: .seconds(2))
        discover()
        pollStatus()
    }

    private func address(of light: Light) -> String? {
        lights.first { $0.value === light }.flatMap { addresses[$0.key] }
    }

    func forget(_ light: Light) {
        guard let id = lights.first(where: { $0.value === light })?.key else { return }
        lights[id] = nil
        addresses[id] = nil
        lastSeen[id] = nil
        saveKnownDevices(knownDevices.filter { $0.device != id })
    }

    private var knownDevices: [GoveeDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.knownDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([GoveeDevice].self, from: data)) ?? []
    }

    private func remember(_ device: GoveeDevice) {
        saveKnownDevices(knownDevices.filter { $0.device != device.device } + [device])
    }

    private func saveKnownDevices(_ devices: [GoveeDevice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.knownDevicesKey)
    }

    private func schedule(every seconds: TimeInterval, _ action: @escaping @MainActor (GoveeLANService) -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: Socket

    private func openSocket() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &enable, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size)) // report EPIPE, don't crash

        var address = sockaddr_in(port: GoveeLAN.listenPort)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            log.error("Binding UDP \(GoveeLAN.listenPort) failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drainSocket() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

    #if DEBUG
    /// Makes the next send fail as if the socket had become unusable (it goes down the same
    /// recovery path as EAGAIN). The descriptor stays owned by the read source, which closes it.
    func simulateStuckSocket() {
        socketFD = -1
    }
    #endif

    /// macOS can leave a UDP socket flow-controlled after a network hiccup, refusing every send with
    /// EAGAIN long after the network is fine again. Only a new socket recovers.
    private func recreateSocket(minimumInterval: Duration) -> Bool {
        guard ContinuousClock.now - lastSocketReset >= minimumInterval else { return false }
        lastSocketReset = .now
        log.notice("Opening a fresh socket")
        readSource?.cancel() // closes the old descriptor
        readSource = nil
        socketFD = -1
        openSocket()
        return socketFD >= 0
    }

    private func drainSocket() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }
            handle(Data(buffer[0..<count]), from: sender.ipString)
        }
    }

    private func send(_ command: GoveeLAN.Command, to ip: String, port: UInt16) {
        guard var address = sockaddr_in(ip: ip, port: port) else { return }
        let payload = GoveeLAN.encode(command)
        var error = sendDatagram(payload, to: &address)
        // A wedged socket fails instantly; retry on a fresh one so a tap isn't lost.
        if let failure = error, Self.socketIsStuck(failure), recreateSocket(minimumInterval: .seconds(5)) {
            error = sendDatagram(payload, to: &address)
        }
        guard let error else { return }

        log.debug("Sending to \(ip, privacy: .public) failed: \(String(cString: strerror(error)), privacy: .public)")
        if error == EHOSTUNREACH {
            // What macOS returns while Local Network access for the app is off or not yet granted.
            for light in lights.values where light.availability != .online {
                light.offlineReason = "No Local Network access"
            }
        }
    }

    /// Returns errno on failure.
    private func sendDatagram(_ payload: Data, to address: inout sockaddr_in) -> Int32? {
        guard socketFD >= 0 else { return EBADF }
        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : nil
    }

    private static func socketIsStuck(_ error: Int32) -> Bool {
        [EAGAIN, ENOBUFS, ENETDOWN, ENETUNREACH, EADDRNOTAVAIL, EBADF, EPIPE].contains(error)
    }
}

/// Marketing names and white ranges for SKUs we know; anything else still works with defaults.
enum GoveeCatalog {
    static func name(for sku: String) -> String {
        switch sku {
        case "H6072": "Lyra"
        default: "Govee \(sku)"
        }
    }

    static func capabilities(for sku: String) -> Light.Capabilities {
        switch sku {
        case "H6072": .init(brightnessRange: 1...100, kelvinRange: 2200...6500, supportsColor: true)
        default: .init(brightnessRange: 1...100, kelvinRange: 2000...9000, supportsColor: true)
        }
    }
}

private extension sockaddr_in {
    init(port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        sin_addr = in_addr(s_addr: INADDR_ANY)
    }

    init?(ip: String, port: UInt16) {
        self.init(port: port)
        guard inet_pton(AF_INET, ip, &sin_addr) == 1 else { return nil }
    }

    var ipString: String {
        var address = sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

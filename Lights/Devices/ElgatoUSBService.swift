import Foundation
import IOKit.hid
import LightsKit
import os

/// Elgato lights connected over USB (Key Light Neo), reached through their HID tunnel.
///
/// The device is opened non-exclusively, so Elgato Control Center can keep running alongside.
/// Every client receives every input report, so replies to Control Center's own polling and the
/// light's change notifications all keep our state current.
final class ElgatoUSBService: LightController {
    private unowned let store: LightStore
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    /// Keyed by the IOHIDDevice's address, which is what report callbacks identify the sender by.
    private var connections: [UInt: Connection] = [:]
    private var pollTimer: Timer?
    private let log = Logger(subsystem: "ro.tirdea.Lights", category: "KeyLight")

    private final class Connection {
        let device: IOHIDDevice
        let light: Light
        /// IOKit writes input reports here for as long as the callback is registered.
        let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: ElgatoHID.reportLength)
        var reassembler = ElgatoHIDReassembler()

        init(device: IOHIDDevice, light: Light) {
            self.device = device
            self.light = light
        }
    }

    init(store: LightStore) {
        self.store = store
    }

    func start() {
        let matching = ElgatoHID.lightProductIDs.map {
            [kIOHIDVendorIDKey: ElgatoHID.vendorID, kIOHIDProductIDKey: $0] as [String: Int]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log.error("Opening the HID manager failed: \(UInt32(bitPattern: result), format: .hex)")
        }

        // Notifications cover changes made elsewhere; polling is only a safety net.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: LightController

    func send(_ change: LightChange, to light: Light) {
        guard let connection = connection(for: light) else { return }
        let state = switch change {
        case .power(let on): ElgatoLightState(on: on ? 1 : 0)
        case .brightness(let value): ElgatoLightState(brightness: value)
        case .kelvin(let kelvin): ElgatoLightState(temperature: ElgatoTemperature.deviceValue(fromKelvin: kelvin))
        case .color, .effect: ElgatoLightState?.none
        }
        if let state { write(ElgatoMessage.setLight(state), to: connection) }
    }

    func refresh(_ light: Light) {
        guard let connection = connection(for: light) else { return }
        write(ElgatoMessage.request("GET", "/elgato/lights"), to: connection)
    }

    // MARK: Device lifecycle

    // The manager is scheduled on the main run loop, so every callback below runs on the main thread.

    private static let deviceMatched: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let service = Unmanaged<ElgatoUSBService>.fromOpaque(context).takeUnretainedValue()
        nonisolated(unsafe) let device = device
        MainActor.assumeIsolated { service.attach(device) }
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let service = Unmanaged<ElgatoUSBService>.fromOpaque(context).takeUnretainedValue()
        let key = key(for: device)
        MainActor.assumeIsolated { service.detach(key) }
    }

    private static let reportReceived: IOHIDReportCallback = { context, result, sender, _, _, report, length in
        guard let context, let sender, result == kIOReturnSuccess else { return }
        let data = Data(bytes: report, count: length)
        let service = Unmanaged<ElgatoUSBService>.fromOpaque(context).takeUnretainedValue()
        let key = UInt(bitPattern: sender)
        MainActor.assumeIsolated { service.receive(data, from: key) }
    }

    private func attach(_ device: IOHIDDevice) {
        let key = Self.key(for: device)
        guard connections[key] == nil else { return }

        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Elgato Key Light"
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? product
        let light = Light(
            id: "elgato-usb:\(serial)",
            kind: .keyLight,
            defaultName: product.replacing("Elgato ", with: ""),
            model: product,
            capabilities: .init(brightnessRange: 3...100, kelvinRange: ElgatoTemperature.kelvinRange, supportsColor: false)
        )
        light.connectionDetail = "USB"
        light.controller = self

        let connection = Connection(device: device, light: light)
        connections[key] = connection
        IOHIDDeviceRegisterInputReportCallback(
            device, connection.reportBuffer, ElgatoHID.reportLength,
            Self.reportReceived, Unmanaged.passUnretained(self).toOpaque()
        )
        store.add(light)
        log.info("Attached \(product, privacy: .public)")

        write(ElgatoMessage.request("GET", "/elgato/accessory-info"), to: connection)
        write(ElgatoMessage.request("GET", "/elgato/lights"), to: connection)
    }

    private func detach(_ key: UInt) {
        guard let connection = connections.removeValue(forKey: key) else { return }
        // IOKit matches the registration to remove by its context.
        IOHIDDeviceRegisterInputReportCallback(
            connection.device, connection.reportBuffer, ElgatoHID.reportLength, nil, Unmanaged.passUnretained(self).toOpaque()
        )
        connection.reportBuffer.deallocate()
        store.remove(connection.light)
        log.info("Detached \(connection.light.model, privacy: .public)")
    }

    // MARK: Messages

    private func receive(_ report: Data, from sender: UInt) {
        guard let connection = connections[sender],
              let packet = ElgatoHID.parse(report: report),
              let message = connection.reassembler.consume(packet) else { return }

        let light = connection.light
        switch ElgatoInbound.decode(kind: message.kind, message: message.message) {
        case .lights(let payload):
            guard let state = payload.lights.first else { return }
            light.applyReported(
                isOn: state.on.map { $0 != 0 },
                brightness: state.brightness,
                color: state.temperature.map { .white(kelvin: ElgatoTemperature.kelvin(fromDeviceValue: $0)) } ?? .unchanged
            )
        case .accessoryInfo(let info):
            apply(info, to: light)
        case .error(let reason):
            log.error("\(light.model, privacy: .public) rejected a request: \(reason, privacy: .public)")
            refresh(light)
        case .unknown:
            break
        }
    }

    private func apply(_ info: ElgatoAccessoryInfo, to light: Light) {
        light.model = info.productName
        if let displayName = info.displayName, !displayName.isEmpty {
            light.defaultName = displayName
        }
        let cap = info.powerInfo?.maximumBrightness
        light.maxBrightness = cap.flatMap { $0 < 100 ? $0 : nil }

        light.connectionDetail = info.firmwareVersion.map { "USB · firmware \($0)" } ?? "USB"
    }

    private func pollAll() {
        for connection in connections.values {
            write(ElgatoMessage.request("GET", "/elgato/lights"), to: connection)
        }
    }

    private func write(_ message: Data, to connection: Connection) {
        for report in ElgatoHID.reports(for: message) {
            let result = report.withUnsafeBytes { bytes in
                IOHIDDeviceSetReport(
                    connection.device, kIOHIDReportTypeOutput, CFIndex(ElgatoHID.reportID),
                    bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count
                )
            }
            guard result == kIOReturnSuccess else {
                log.error("Writing to \(connection.light.model, privacy: .public) failed: \(UInt32(bitPattern: result), format: .hex)")
                return
            }
        }
    }

    private func connection(for light: Light) -> Connection? {
        connections.values.first { $0.light === light }
    }

    private nonisolated static func key(for device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }
}

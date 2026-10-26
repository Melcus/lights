import AppKit
import LightsKit
import Observation

/// Night Shift for the lights: follows the sun's elevation to move every white light between daytime
/// and night values for colour temperature and, optionally, brightness.
///
/// Only lights that are on and showing white are adjusted, and lights are never switched on.
/// Changing a light by hand pauses it until the next sunrise or sunset, so a manual choice sticks for
/// a while but darkness still wins in the end.
@Observable
final class AdaptiveLighting {
    enum Phase {
        case day, dusk, night, dawn
    }

    struct Place {
        var name: String
        var sun: SunCalculator
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            pausedUntil = [:]
            deliveries = [:]
            update()
        }
    }

    var dayKelvin: Int {
        didSet { defaults.set(dayKelvin, forKey: Keys.day); update() }
    }

    var nightKelvin: Int {
        didSet { defaults.set(nightKelvin, forKey: Keys.night); update() }
    }

    var adjustsBrightness: Bool {
        didSet {
            defaults.set(adjustsBrightness, forKey: Keys.adjustsBrightness)
            deliveries = [:]
            update()
        }
    }

    /// Percent of each light's own maximum, so a light limited by its power source scales with it.
    var dayBrightness: Int {
        didSet { defaults.set(dayBrightness, forKey: Keys.dayBrightness); update() }
    }

    var nightBrightness: Int {
        didSet { defaults.set(nightBrightness, forKey: Keys.nightBrightness); update() }
    }

    private(set) var now = Date()
    private(set) var place = AdaptiveLighting.placeFromTimeZone()
    private(set) var pausedUntil: [String: Date] = [:]

    @ObservationIgnored private unowned let store: LightStore
    @ObservationIgnored private let defaults: UserDefaults
    /// What was last sent to each light, to tell a lost command or a device limit from a change
    /// made elsewhere (Control Center, the Govee app, the light's own controls).
    @ObservationIgnored private var deliveries: [String: Delivery] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

    struct Target: Equatable {
        var kelvin: Int
        /// nil when brightness isn't adjusted.
        var brightness: Int?
    }

    private struct Delivery {
        /// What was asked for; a new target is sent only once the sun has moved it on.
        var target: Target
        /// What the light should report back. Starts as `target`, becomes the light's own values when
        /// it can't go that far.
        var expected: Target
        var sentAt: ContinuousClock.Instant
        var isRetry: Bool
    }

    private enum Keys {
        static let enabled = "adaptive.enabled"
        static let day = "adaptive.dayKelvin"
        static let night = "adaptive.nightKelvin"
        static let adjustsBrightness = "adaptive.adjustsBrightness"
        static let dayBrightness = "adaptive.dayBrightness"
        static let nightBrightness = "adaptive.nightBrightness"
    }

    init(store: LightStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        dayKelvin = defaults.object(forKey: Keys.day) as? Int ?? 5500
        nightKelvin = defaults.object(forKey: Keys.night) as? Int ?? 2700
        adjustsBrightness = defaults.object(forKey: Keys.adjustsBrightness) as? Bool ?? true
        // Brighter once it's dark outside, when there's no daylight to help.
        dayBrightness = defaults.object(forKey: Keys.dayBrightness) as? Int ?? 50
        nightBrightness = defaults.object(forKey: Keys.nightBrightness) as? Int ?? 80
    }

    func start() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let observe = { (center: NotificationCenter, name: Notification.Name, handler: @escaping @MainActor () -> Void) in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated(handler) }
        }
        notificationObservers = [
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.update() },
            observe(.default, .NSSystemTimeZoneDidChange) { [weak self] in
                self?.place = Self.placeFromTimeZone()
                self?.update()
            },
        ]

        // React as soon as a light comes on, (re)connects or reports other values, wherever that happened.
        Task { [weak self, store] in
            for await _ in Observations({
                store.lights.map { "\($0.id) \($0.isOn) \($0.isReachable) \($0.kelvin) \($0.brightness) \($0.color == nil) \($0.effect == nil)" }
            }) {
                self?.update()
            }
        }
        update()
    }

    // MARK: State

    var targetKelvin: Int {
        AdaptiveCurve.kelvin(forSolarElevation: place.sun.elevation(at: now), day: dayKelvin, night: nightKelvin)
    }

    /// Percent of a light's maximum.
    var targetBrightness: Int {
        AdaptiveCurve.brightness(forSolarElevation: place.sun.elevation(at: now), day: dayBrightness, night: nightBrightness)
    }

    /// "5500 K at 50%" or just "5500 K".
    var targetSummary: String {
        adjustsBrightness ? "\(targetKelvin) K at \(targetBrightness)%" : "\(targetKelvin) K"
    }

    var phase: Phase {
        let elevation = place.sun.elevation(at: now)
        if elevation >= AdaptiveCurve.dayElevation { return .day }
        if elevation <= AdaptiveCurve.nightElevation { return .night }
        return place.sun.elevation(at: now.addingTimeInterval(600)) < elevation ? .dusk : .dawn
    }

    var sunTimesToday: (sunrise: Date, sunset: Date)? {
        place.sun.sunTimes(around: Self.noon(of: now))
    }

    /// Lights showing a colour or a scene were set by hand, so they don't follow.
    func follows(_ light: Light) -> Bool {
        isEnabled && light.color == nil && light.effect == nil && !isPaused(light)
    }

    func isPaused(_ light: Light) -> Bool {
        pausedUntil[light.id].map { $0 > now } ?? false
    }

    /// Targets across the local day, for drawing the daily curves.
    func dayProfile(steps: Int = 96) -> [(fraction: Double, kelvin: Int, brightness: Int)] {
        let (start, end) = Self.dayBounds(of: now)
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            let moment = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
            let elevation = place.sun.elevation(at: moment)
            return (
                fraction,
                AdaptiveCurve.kelvin(forSolarElevation: elevation, day: dayKelvin, night: nightKelvin),
                AdaptiveCurve.brightness(forSolarElevation: elevation, day: dayBrightness, night: nightBrightness)
            )
        }
    }

    var dayFraction: Double {
        let (start, end) = Self.dayBounds(of: now)
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    // MARK: Actions

    /// A change made by hand: step aside until the next sunrise or sunset.
    func userAdjusted(_ light: Light) {
        guard isEnabled else { return }
        pause(light)
    }

    func pause(_ light: Light) {
        now = .now
        pausedUntil[light.id] = nextSunEvent()
        deliveries[light.id] = nil
    }

    /// Follow again and re-apply right away, whatever the light shows now. A light showing an RGB
    /// colour goes back to white.
    func resume(_ light: Light) {
        now = .now
        pausedUntil[light.id] = nil
        deliveries[light.id] = nil
        guard isEnabled, light.isReachable, light.isOn else { return }
        send(target(for: light), to: light)
    }

    func update() {
        now = .now
        guard isEnabled else { return }
        for light in store.lights where light.isReachable {
            guard light.isOn else {
                deliveries[light.id] = nil // re-apply when it comes back on
                continue
            }
            guard follows(light) else { continue }

            if let delivery = deliveries[light.id], !Self.reports(light, match: delivery.expected) {
                // The light reports something other than what was sent.
                let isRecent = ContinuousClock.now - delivery.sentAt < .seconds(15)
                if isRecent, !delivery.isRetry {
                    send(delivery.target, to: light, isRetry: true) // probably lost on the way
                } else if isRecent {
                    // The light can't go there; accept its limit.
                    deliveries[light.id]?.expected = Target(
                        kelvin: light.kelvin, brightness: delivery.expected.brightness == nil ? nil : light.brightness
                    )
                } else {
                    pause(light) // changed elsewhere, which counts as a manual change
                }
                continue
            }

            let target = target(for: light)
            if let delivery = deliveries[light.id], !Self.hasMoved(from: delivery.target, to: target) { continue }
            send(target, to: light)
        }
    }

    private func send(_ target: Target, to light: Light, isRetry: Bool = false) {
        deliveries[light.id] = Delivery(target: target, expected: target, sentAt: .now, isRetry: isRetry)
        store.applyAdaptive(kelvin: target.kelvin, brightness: target.brightness, to: light)
    }

    private func target(for light: Light) -> Target {
        let kelvinRange = light.capabilities.kelvinRange
        let kelvin = min(max(targetKelvin, kelvinRange.lowerBound), kelvinRange.upperBound)
        guard adjustsBrightness else { return Target(kelvin: kelvin, brightness: nil) }

        let limit = light.brightnessLimit
        let brightness = Int((Double(limit) * Double(targetBrightness) / 100).rounded())
        return Target(kelvin: kelvin, brightness: min(max(brightness, light.capabilities.brightnessRange.lowerBound), limit))
    }

    /// Elgato reports temperature in mireds, so Kelvin only round-trips to within a step.
    private static func reports(_ light: Light, match expected: Target) -> Bool {
        abs(light.kelvin - expected.kelvin) <= 100 && expected.brightness.map { abs(light.brightness - $0) <= 2 } ?? true
    }

    private static func hasMoved(from old: Target, to new: Target) -> Bool {
        if abs(old.kelvin - new.kelvin) >= 50 { return true }
        switch (old.brightness, new.brightness) {
        case let (old?, new?): return abs(old - new) >= 2
        case (nil, nil): return false
        default: return true
        }
    }

    func nextSunEvent() -> Date {
        let today = place.sun.sunTimes(around: Self.noon(of: now))
        let tomorrow = place.sun.sunTimes(around: Self.noon(of: now.addingTimeInterval(86_400)))
        let events = [today?.sunrise, today?.sunset, tomorrow?.sunrise, tomorrow?.sunset].compactMap { $0 }
        return events.filter { $0 > now }.min() ?? now.addingTimeInterval(12 * 3600)
    }

    // MARK: Location

    /// Sun times come from the time zone's reference city in the IANA zone table, which avoids asking
    /// for location access and is within minutes for most places.
    private static func placeFromTimeZone() -> Place {
        let zone = TimeZone.current
        let city = zone.identifier.split(separator: "/").last.map { String($0).replacing("_", with: " ") } ?? zone.identifier
        let table = ["/usr/share/zoneinfo/zone.tab", "/var/db/timezone/zoneinfo/zone.tab"]
            .lazy.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.first ?? ""
        if let coordinates = ZoneTable.coordinates(for: zone.identifier, in: table) {
            return Place(name: city, sun: SunCalculator(coordinates))
        }
        // Unknown zone: longitude from the standard UTC offset, a temperate latitude.
        let standardOffset = Double(zone.secondsFromGMT() - Int(zone.daylightSavingTimeOffset())) / 3600
        return Place(name: "\(city) (approximate)", sun: SunCalculator(Coordinates(latitude: 45, longitude: standardOffset * 15)))
    }

    private static func noon(of date: Date) -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    private static func dayBounds(of date: Date) -> (start: Date, end: Date) {
        let start = Calendar.current.startOfDay(for: date)
        return (start, Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }
}

extension AdaptiveLighting.Phase {
    var symbolName: String {
        switch self {
        case .day: "sun.max.fill"
        case .dusk: "sunset.fill"
        case .night: "moon.stars.fill"
        case .dawn: "sunrise.fill"
        }
    }

    var summary: String {
        switch self {
        case .day: "daylight"
        case .dusk: "evening transition"
        case .night: "night"
        case .dawn: "morning transition"
        }
    }
}

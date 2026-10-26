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
            rules = AdaptiveRules()
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
            rules.forgetDeliveries()
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
    /// Pauses, and what was sent to each light.
    private(set) var rules = AdaptiveRules()

    @ObservationIgnored private unowned let store: LightStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

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

    /// Percent of each light's maximum, or nil when brightness isn't adjusted.
    private var brightnessShare: Int? {
        adjustsBrightness ? targetBrightness : nil
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

    var pausedUntil: [String: Date] { rules.pausedUntil }

    /// Lights showing a colour or a scene were set by hand, so they don't follow.
    func follows(_ light: Light) -> Bool {
        isEnabled && rules.follows(light.state, at: now)
    }

    func isPaused(_ light: Light) -> Bool {
        rules.isPaused(light.id, at: now)
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
        now = .now
        rules.pause(light.id, until: nextSunEvent())
    }

    /// Follow again and re-apply right away, whatever the light shows now. A light showing an RGB
    /// colour goes back to white.
    func resume(_ light: Light) {
        now = .now
        guard isEnabled, let target = rules.resume(light.state, kelvin: targetKelvin, brightness: brightnessShare, at: .now) else {
            return
        }
        send(target, to: light)
    }

    func update() {
        now = .now
        guard isEnabled else { return }
        var rules = self.rules
        let sends = rules.update(
            store.lights.map(\.state), kelvin: targetKelvin, brightness: brightnessShare,
            now: now, instant: .now, nextSunEvent: nextSunEvent()
        )
        // Only real changes, or everything showing a pause would redraw every minute.
        if rules != self.rules { self.rules = rules }
        for (id, target) in sends {
            if let light = store.light(id: id) { send(target, to: light) }
        }
    }

    private func send(_ target: AdaptiveRules.Target, to light: Light) {
        store.applyAdaptive(kelvin: target.kelvin, brightness: target.brightness, to: light)
    }

    private func nextSunEvent() -> Date {
        place.sun.nextSunriseOrSunset(after: now)
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

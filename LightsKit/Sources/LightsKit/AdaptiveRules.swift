import Foundation

/// The rules of adaptive lighting, apart from timers and devices: what to send to each light, and
/// when to step aside.
///
/// Only lights that are on and showing white follow, and lights are never switched on. A light
/// changed by hand, in Lights or anywhere else, is paused until the next sunrise or sunset.
public struct AdaptiveRules: Equatable, Sendable {
    /// White for one light and, when brightness is adjusted, its brightness.
    public struct Target: Equatable, Sendable {
        public var kelvin: Int
        /// nil when brightness isn't adjusted.
        public var brightness: Int?

        public init(kelvin: Int, brightness: Int?) {
            self.kelvin = kelvin
            self.brightness = brightness
        }
    }

    private struct Delivery: Equatable, Sendable {
        /// What was asked for; a new target is sent only once the sun has moved it on.
        var target: Target
        /// What the light should report back. Starts as `target`, becomes the light's own values when
        /// it can't go that far.
        var expected: Target
        var sentAt: ContinuousClock.Instant
        var isRetry: Bool
    }

    /// How long a light has to report what it was sent. A difference after that was made elsewhere.
    public static let confirmationTime = Duration.seconds(15)

    public private(set) var pausedUntil: [String: Date] = [:]
    /// What was last sent to each light, to tell a lost command or a device limit from a change
    /// made elsewhere (Control Center, the Govee app, the light's own controls).
    private var deliveries: [String: Delivery] = [:]

    public init() {}

    public func isPaused(_ id: String, at now: Date) -> Bool {
        pausedUntil[id].map { $0 > now } ?? false
    }

    /// Lights showing a colour or a scene were set by hand, so they don't follow.
    public func follows(_ light: LightState, at now: Date) -> Bool {
        light.showsWhite && !isPaused(light.id, at: now)
    }

    /// A change made by hand: step aside until `date`, the next sunrise or sunset.
    public mutating func pause(_ id: String, until date: Date) {
        pausedUntil[id] = date
        deliveries[id] = nil
    }

    /// Follows again and re-applies straight away, whatever the light shows (a colour goes back to
    /// white). Returns what to send, or nil when the light is off or out of reach.
    public mutating func resume(_ light: LightState, kelvin: Int, brightness: Int?, at instant: ContinuousClock.Instant) -> Target? {
        pausedUntil[light.id] = nil
        deliveries[light.id] = nil
        guard light.isReachable, light.isOn else { return nil }
        let target = Self.target(for: light, kelvin: kelvin, brightness: brightness)
        deliveries[light.id] = Delivery(target: target, expected: target, sentAt: instant, isRetry: false)
        return target
    }

    /// Sends every light its target again on the next update.
    public mutating func forgetDeliveries() {
        deliveries = [:]
    }

    /// What to send now, by light ID.
    /// - Parameters:
    ///   - kelvin: the adaptive colour temperature right now.
    ///   - brightness: percent of each light's maximum, or nil when brightness isn't adjusted.
    ///   - nextSunEvent: when a pause that starts now ends.
    public mutating func update(
        _ lights: [LightState], kelvin: Int, brightness: Int?, now: Date, instant: ContinuousClock.Instant, nextSunEvent: Date
    ) -> [String: Target] {
        var sends: [String: Target] = [:]
        for light in lights where light.isReachable {
            guard light.isOn else {
                deliveries[light.id] = nil // re-apply when it comes back on
                continue
            }
            guard follows(light, at: now) else { continue }

            if let delivery = deliveries[light.id], !Self.reports(light, match: delivery.expected) {
                // The light reports something other than what was sent.
                let isRecent = instant - delivery.sentAt < Self.confirmationTime
                if isRecent, !delivery.isRetry {
                    // Probably lost on the way.
                    deliveries[light.id] = Delivery(target: delivery.target, expected: delivery.target, sentAt: instant, isRetry: true)
                    sends[light.id] = delivery.target
                } else if isRecent {
                    // The light can't go there; accept its limit.
                    deliveries[light.id]?.expected = Target(
                        kelvin: light.kelvin, brightness: delivery.expected.brightness == nil ? nil : light.brightness
                    )
                } else {
                    pause(light.id, until: nextSunEvent) // changed elsewhere, which counts as a manual change
                }
                continue
            }

            let target = Self.target(for: light, kelvin: kelvin, brightness: brightness)
            if let delivery = deliveries[light.id], !Self.hasMoved(from: delivery.target, to: target) { continue }
            deliveries[light.id] = Delivery(target: target, expected: target, sentAt: instant, isRetry: false)
            sends[light.id] = target
        }
        return sends
    }

    /// The adaptive values fitted to one light: its own white range, and brightness as a share of
    /// what it can do right now, so a light limited by its power source scales with it.
    public static func target(for light: LightState, kelvin: Int, brightness: Int?) -> Target {
        let kelvin = light.fittedKelvin(kelvin)
        guard let brightness else { return Target(kelvin: kelvin, brightness: nil) }
        let share = Int((Double(light.brightnessLimit) * Double(brightness) / 100).rounded())
        return Target(kelvin: kelvin, brightness: light.fittedBrightness(share))
    }

    /// Elgato reports temperature in mireds, so Kelvin only round-trips to within a step.
    private static func reports(_ light: LightState, match expected: Target) -> Bool {
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
}

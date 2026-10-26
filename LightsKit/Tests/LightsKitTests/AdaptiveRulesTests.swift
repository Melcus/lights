import Foundation
import Testing
@testable import LightsKit

struct AdaptiveRulesTests {
    private typealias Target = AdaptiveRules.Target

    private let start = ContinuousClock.now
    private let noon = Date(timeIntervalSince1970: 1_792_000_000)
    private var sunset: Date { noon.addingTimeInterval(5 * 3600) }

    @Test func sendsTheTargetToWhiteLightsThatAreOn() {
        var rules = AdaptiveRules()
        let sends = update(&rules, [lamp()], kelvin: 5500, brightness: 50)
        #expect(sends == ["lamp": Target(kelvin: 5500, brightness: 50)])
    }

    @Test func leavesColoursScenesAndLightsThatAreOffAlone() {
        var rules = AdaptiveRules()
        let lights = [
            lamp("off", isOn: false),
            lamp("colour", color: RGB(r: 255, g: 0, b: 0)),
            lamp("scene", scene: "Northern Lights"),
            lamp("gone", isReachable: false),
        ]
        #expect(update(&rules, lights, kelvin: 5500, brightness: 50).isEmpty)
    }

    @Test func fitsTheTargetToEachLight() {
        // A Key Light Neo on weak USB power: 2900 to 7000 K, 3 to 100%, but no more than 40%.
        let keyLight = lamp(brightnessRange: 3...100, limit: 40, kelvinRange: 2900...7000)
        #expect(AdaptiveRules.target(for: keyLight, kelvin: 2700, brightness: 80) == Target(kelvin: 2900, brightness: 32))
        #expect(AdaptiveRules.target(for: keyLight, kelvin: 7500, brightness: 5) == Target(kelvin: 7000, brightness: 3))
        #expect(AdaptiveRules.target(for: keyLight, kelvin: 4000, brightness: nil) == Target(kelvin: 4000, brightness: nil))
    }

    @Test func waitsForTheSunToMoveTheTargetOn() {
        var rules = AdaptiveRules()
        _ = update(&rules, [lamp()], kelvin: 5500, brightness: 50)
        let confirmed = lamp(brightness: 50, kelvin: 5500)
        #expect(update(&rules, [confirmed], kelvin: 5500, brightness: 51, after: .seconds(60)).isEmpty)
        #expect(update(&rules, [confirmed], kelvin: 5500, brightness: 52, after: .seconds(120)) == ["lamp": Target(kelvin: 5500, brightness: 52)])
        #expect(update(&rules, [lamp(brightness: 52, kelvin: 5500)], kelvin: 5450, brightness: 52, after: .seconds(180))
            == ["lamp": Target(kelvin: 5450, brightness: 52)])
    }

    @Test func retriesOnceThenAcceptsWhatTheLightCanDo() {
        var rules = AdaptiveRules()
        _ = update(&rules, [lamp()], kelvin: 5500, brightness: 50)
        let short = lamp(brightness: 50, kelvin: 5000)
        #expect(update(&rules, [short], kelvin: 5500, brightness: 50, after: .seconds(2)) == ["lamp": Target(kelvin: 5500, brightness: 50)])
        #expect(update(&rules, [short], kelvin: 5500, brightness: 50, after: .seconds(4)).isEmpty)
        // Well after the window, the light still shows its own limit: no more sends, and no pause.
        #expect(update(&rules, [short], kelvin: 5500, brightness: 50, after: .seconds(60)).isEmpty)
        #expect(!rules.isPaused("lamp", at: noon))
    }

    @Test func aChangeMadeElsewherePausesUntilTheNextSunEvent() {
        var rules = AdaptiveRules()
        _ = update(&rules, [lamp()], kelvin: 5500, brightness: 50)
        #expect(update(&rules, [lamp(brightness: 50, kelvin: 5500)], kelvin: 5500, brightness: 50, after: .seconds(2)).isEmpty)

        // Dimmed in Control Center a minute later.
        let dimmed = lamp(brightness: 20, kelvin: 5500)
        #expect(update(&rules, [dimmed], kelvin: 5500, brightness: 50, after: .seconds(60)).isEmpty)
        #expect(rules.pausedUntil["lamp"] == sunset)
        #expect(!rules.follows(dimmed, at: noon.addingTimeInterval(3600)))
        #expect(update(&rules, [dimmed], kelvin: 5500, brightness: 50, at: noon.addingTimeInterval(3600)).isEmpty)

        // At sunset it follows again.
        #expect(update(&rules, [dimmed], kelvin: 3600, brightness: 65, at: sunset.addingTimeInterval(1))
            == ["lamp": Target(kelvin: 3600, brightness: 65)])
    }

    @Test func autoReappliesStraightAwayAfterAManualChange() {
        var rules = AdaptiveRules()
        rules.pause("lamp", until: sunset)
        #expect(update(&rules, [lamp()], kelvin: 5500, brightness: 50).isEmpty)

        // The Auto pill brings back white, even from a colour.
        let red = lamp(color: RGB(r: 255, g: 0, b: 0))
        #expect(rules.resume(red, kelvin: 5500, brightness: 50, at: start) == Target(kelvin: 5500, brightness: 50))
        #expect(!rules.isPaused("lamp", at: noon))
        #expect(update(&rules, [lamp(brightness: 50, kelvin: 5500)], kelvin: 5500, brightness: 50, after: .seconds(2)).isEmpty)
    }

    @Test func autoSendsNothingToALightThatIsOff() {
        var rules = AdaptiveRules()
        rules.pause("lamp", until: sunset)
        #expect(rules.resume(lamp(isOn: false), kelvin: 5500, brightness: 50, at: start) == nil)
        #expect(!rules.isPaused("lamp", at: noon))
    }

    @Test func aLightSwitchedBackOnGetsTheTargetAgain() {
        var rules = AdaptiveRules()
        _ = update(&rules, [lamp()], kelvin: 5500, brightness: 50)
        _ = update(&rules, [lamp(isOn: false)], kelvin: 5500, brightness: 50, after: .seconds(60))
        // It comes back on showing what it had before; that's no manual change.
        let stale = lamp(brightness: 80, kelvin: 2700)
        #expect(update(&rules, [stale], kelvin: 5500, brightness: 50, after: .seconds(120)) == ["lamp": Target(kelvin: 5500, brightness: 50)])
        #expect(!rules.isPaused("lamp", at: noon))
    }

    @Test func temperatureRoundedByTheLightCountsAsDelivered() {
        var rules = AdaptiveRules()
        _ = update(&rules, [lamp()], kelvin: 3000, brightness: 50)
        // Nanoleaf and Elgato store mireds: 3000 K reads back as 3003 K.
        #expect(update(&rules, [lamp(brightness: 50, kelvin: 3003)], kelvin: 3000, brightness: 50, after: .seconds(2)).isEmpty)
        #expect(update(&rules, [lamp(brightness: 50, kelvin: 3003)], kelvin: 3000, brightness: 50, after: .seconds(60)).isEmpty)
        #expect(!rules.isPaused("lamp", at: noon))
    }

    @Test func pausesEndAtTheNextSunriseOrSunset() throws {
        let bucharest = SunCalculator(Coordinates(latitude: 44 + 26.0 / 60, longitude: 26.1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bucharest"))

        // 2026-10-16: sunrise 04:32 UTC, sunset 15:30 UTC.
        let beforeDawn = bucharest.nextSunriseOrSunset(after: date("2026-10-16T02:00:00Z"), calendar: calendar)
        #expect(abs(beforeDawn.timeIntervalSince(date("2026-10-16T04:32:00Z"))) < 180)
        let midday = bucharest.nextSunriseOrSunset(after: date("2026-10-16T09:00:00Z"), calendar: calendar)
        #expect(abs(midday.timeIntervalSince(date("2026-10-16T15:30:00Z"))) < 180)
        let evening = bucharest.nextSunriseOrSunset(after: date("2026-10-16T18:00:00Z"), calendar: calendar)
        #expect(abs(evening.timeIntervalSince(date("2026-10-17T04:33:00Z"))) < 180)

        // No sunrise during the polar night: twelve hours.
        let tromso = SunCalculator(Coordinates(latitude: 69.65, longitude: 18.96))
        let polarNight = date("2026-12-21T11:00:00Z")
        #expect(tromso.nextSunriseOrSunset(after: polarNight, calendar: calendar) == polarNight.addingTimeInterval(12 * 3600))
    }

    // MARK: Helpers

    private func update(
        _ rules: inout AdaptiveRules, _ lights: [LightState], kelvin: Int, brightness: Int?,
        after elapsed: Duration = .zero, at now: Date? = nil
    ) -> [String: Target] {
        rules.update(
            lights, kelvin: kelvin, brightness: brightness, now: now ?? noon, instant: start.advanced(by: elapsed), nextSunEvent: sunset
        )
    }

    private func lamp(
        _ id: String = "lamp", isReachable: Bool = true, isOn: Bool = true, brightness: Int = 30, kelvin: Int = 4000,
        color: RGB? = nil, scene: String? = nil, brightnessRange: ClosedRange<Int> = 1...100, limit: Int? = nil,
        kelvinRange: ClosedRange<Int> = 2000...7000
    ) -> LightState {
        LightState(
            id: id, isReachable: isReachable, isOn: isOn, brightness: brightness, kelvin: kelvin, color: color, scene: scene,
            brightnessRange: brightnessRange, brightnessLimit: limit, kelvinRange: kelvinRange, supportsColor: true
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

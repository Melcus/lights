import Foundation
import Testing
@testable import LightsKit

struct DaylightTests {
    private let bucharest = SunCalculator(Coordinates(latitude: 44 + 26.0 / 60, longitude: 26.1))

    /// Published times for Bucharest (weather2travel, listed in EET = UTC+2), converted to UTC.
    @Test(arguments: [
        ("2026-10-16T09:00:00Z", "2026-10-16T04:32:00Z", "2026-10-16T15:30:00Z"),
        ("2026-10-31T10:00:00Z", "2026-10-31T04:51:00Z", "2026-10-31T15:07:00Z"),
    ])
    func sunTimesMatchAlmanac(localNoon: String, sunrise: String, sunset: String) throws {
        let times = try #require(bucharest.sunTimes(around: date(localNoon)))
        #expect(abs(times.sunrise.timeIntervalSince(date(sunrise))) < 180)
        #expect(abs(times.sunset.timeIntervalSince(date(sunset))) < 180)
    }

    @Test func noSunriseDuringPolarNightOrMidnightSun() {
        let tromso = SunCalculator(Coordinates(latitude: 69.65, longitude: 18.96))
        #expect(tromso.sunTimes(around: date("2026-12-21T11:00:00Z")) == nil)
        #expect(tromso.sunTimes(around: date("2026-06-21T11:00:00Z")) == nil)
    }

    @Test func elevationAtEquinoxNoonIsNinetyMinusLatitude() {
        // Solar noon in Bucharest on the March equinox is about 10:21 UTC.
        let elevation = bucharest.elevation(at: date("2026-03-20T10:21:00Z"))
        #expect(abs(elevation - (90 - 44.43)) < 1)
        #expect(bucharest.elevation(at: date("2026-03-20T22:21:00Z")) < -30)
    }

    @Test func adaptiveTemperatureFollowsElevation() {
        #expect(AdaptiveCurve.kelvin(forSolarElevation: 40, day: 5500, night: 2700) == 5500)
        #expect(AdaptiveCurve.kelvin(forSolarElevation: -12, day: 5500, night: 2700) == 2700)
        // Halfway through the transition sits halfway in mireds: 1e6 / ((1e6/5500 + 1e6/2700) / 2) ≈ 3622 K.
        #expect(AdaptiveCurve.kelvin(forSolarElevation: 3, day: 5500, night: 2700) == 3600)

        let samples = stride(from: 15.0, through: -8, by: -1).map {
            AdaptiveCurve.kelvin(forSolarElevation: $0, day: 5500, night: 2700)
        }
        #expect(samples == samples.sorted(by: >))
    }

    @Test func adaptiveBrightnessRunsBetweenDayAndNight() {
        #expect(AdaptiveCurve.brightness(forSolarElevation: 40, day: 50, night: 80) == 50)
        #expect(AdaptiveCurve.brightness(forSolarElevation: -12, day: 50, night: 80) == 80)
        #expect(AdaptiveCurve.brightness(forSolarElevation: 3, day: 50, night: 80) == 65)
        // Dimming towards night works the same way.
        #expect(AdaptiveCurve.brightness(forSolarElevation: -12, day: 90, night: 30) == 30)
    }

    @Test func parsesZoneTableCoordinates() throws {
        let table = """
        # tz zone descriptions
        GB\t+513030-0000731\tEurope/London
        RO\t+4426+02606\tEurope/Bucharest
        US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
        """
        let bucharest = try #require(ZoneTable.coordinates(for: "Europe/Bucharest", in: table))
        #expect(abs(bucharest.latitude - 44.4333) < 0.001 && abs(bucharest.longitude - 26.1) < 0.001)
        let newYork = try #require(ZoneTable.coordinates(for: "America/New_York", in: table))
        #expect(abs(newYork.latitude - 40.7142) < 0.001 && abs(newYork.longitude + 74.0064) < 0.001)
        #expect(ZoneTable.coordinates(for: "Mars/Olympus_Mons", in: table) == nil)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

import Foundation

public struct Coordinates: Equatable, Sendable {
    public var latitude: Double
    /// East positive.
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Sun position after NOAA's "General Solar Position Calculations": good to a minute or two, plenty
/// for lighting. Everything is computed in UTC, so time zones and daylight saving never enter.
public struct SunCalculator: Sendable {
    public let coordinates: Coordinates

    public init(_ coordinates: Coordinates) {
        self.coordinates = coordinates
    }

    /// Degrees above the horizon, negative once the sun has set.
    public func elevation(at date: Date) -> Double {
        let solar = Self.solarParameters(at: date)
        let trueSolarTime = Self.minutesSinceUTCMidnight(date) + solar.equationOfTime + 4 * coordinates.longitude
        let hourAngle = radians(trueSolarTime / 4 - 180)
        let latitude = radians(coordinates.latitude)
        let cosZenith = sin(latitude) * sin(solar.declination)
            + cos(latitude) * cos(solar.declination) * cos(hourAngle)
        return 90 - degrees(acos(min(max(cosZenith, -1), 1)))
    }

    /// Sunrise and sunset of the day around `date` (pass local noon), or nil during polar day or night.
    public func sunTimes(around date: Date) -> (sunrise: Date, sunset: Date)? {
        let solar = Self.solarParameters(at: date)
        let latitude = radians(coordinates.latitude)
        // 90.833° allows for atmospheric refraction and the size of the sun's disc.
        let cosHourAngle = cos(radians(90.833)) / (cos(latitude) * cos(solar.declination))
            - tan(latitude) * tan(solar.declination)
        guard (-1...1).contains(cosHourAngle) else { return nil }

        let hourAngle = degrees(acos(cosHourAngle))
        let utcMidnight = date.addingTimeInterval(-Self.minutesSinceUTCMidnight(date) * 60)
        func time(minutes: Double) -> Date { utcMidnight.addingTimeInterval(minutes * 60) }
        return (
            time(minutes: 720 - 4 * (coordinates.longitude + hourAngle) - solar.equationOfTime),
            time(minutes: 720 - 4 * (coordinates.longitude - hourAngle) - solar.equationOfTime)
        )
    }

    private static func solarParameters(at date: Date) -> (equationOfTime: Double, declination: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let daysInYear = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
        let hours = minutesSinceUTCMidnight(date) / 60
        let year = 2 * .pi / daysInYear * (dayOfYear - 1 + (hours - 12) / 24)

        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(year) - 0.032077 * sin(year)
            - 0.014615 * cos(2 * year) - 0.040849 * sin(2 * year))
        let declination = 0.006918 - 0.399912 * cos(year) + 0.070257 * sin(year)
            - 0.006758 * cos(2 * year) + 0.000907 * sin(2 * year)
            - 0.002697 * cos(3 * year) + 0.00148 * sin(3 * year)
        return (equationOfTime, declination)
    }

    private static func minutesSinceUTCMidnight(_ date: Date) -> Double {
        let seconds = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        return (seconds < 0 ? seconds + 86_400 : seconds) / 60
    }
}

/// Night Shift-style daylight curve: daytime values while the sun is well up, easing to night values
/// between golden hour and the end of civil twilight.
public enum AdaptiveCurve {
    /// At or above this solar elevation, in degrees, lights use their daytime values.
    public static let dayElevation = 12.0
    /// At or below this elevation (the end of civil twilight) they use their night values.
    public static let nightElevation = -6.0

    /// 0 in daylight, 1 at night, smoothly eased in between.
    public static func nightProgress(forSolarElevation elevation: Double) -> Double {
        let progress = min(max((dayElevation - elevation) / (dayElevation - nightElevation), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    /// Rounded to 50 K, the step Elgato's lights resolve.
    public static func kelvin(forSolarElevation elevation: Double, day: Int, night: Int) -> Int {
        // Interpolate in mireds, which change evenly to the eye; Kelvin does not.
        let dayMired = 1_000_000 / Double(day)
        let nightMired = 1_000_000 / Double(night)
        let mired = dayMired + (nightMired - dayMired) * nightProgress(forSolarElevation: elevation)
        return Int((1_000_000 / mired / 50).rounded()) * 50
    }

    /// Brightness in percent; either end may be the brighter one.
    public static func brightness(forSolarElevation elevation: Double, day: Int, night: Int) -> Int {
        Int((Double(day) + Double(night - day) * nightProgress(forSolarElevation: elevation)).rounded())
    }
}

/// Reference coordinates of IANA time zones (`zone.tab`), for estimating sun times without asking
/// for location access.
public enum ZoneTable {
    public static func coordinates(for identifier: String, in table: String) -> Coordinates? {
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] == identifier else { continue }
            return parseISO6709(fields[1])
        }
        return nil
    }

    /// `+4426+02606` (±DDMM±DDDMM) or `+404251-0740023` (±DDMMSS±DDDMMSS).
    static func parseISO6709(_ text: Substring) -> Coordinates? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }),
              let latitude = angle(text[..<split], degreeDigits: 2),
              let longitude = angle(text[split...], degreeDigits: 3) else { return nil }
        return Coordinates(latitude: latitude, longitude: longitude)
    }

    private static func angle(_ text: Substring, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().compactMap(\.wholeNumberValue)
        guard digits.count == text.count - 1, digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4 else {
            return nil
        }
        func number(_ range: Range<Int>) -> Double { Double(digits[range].reduce(0) { $0 * 10 + $1 }) }
        var value = number(0..<degreeDigits) + number(degreeDigits..<degreeDigits + 2) / 60
        if digits.count == degreeDigits + 4 { value += number(degreeDigits + 2..<degreeDigits + 4) / 3600 }
        return sign == "-" ? -value : value
    }
}

private func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
private func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

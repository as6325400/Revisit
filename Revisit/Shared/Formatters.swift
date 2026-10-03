import Foundation

nonisolated enum Formatters {
    /// "5.21 km", or "850 m" under one kilometer.
    static func distance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.2f km", meters / 1000)
    }

    /// "28:13" or "1:02:03".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Pace or speed in the style that fits the workout type, e.g. "5'24\" /km", "24.3 km/h", "2'05\" /100m".
    static func pace(distance meters: Double, duration seconds: TimeInterval, style: PaceStyle) -> String {
        guard meters > 0, seconds > 0 else { return "—" }
        return pace(speed: meters / seconds, style: style)
    }

    /// Same as `pace(distance:duration:style:)`, from a speed in m/s.
    static func pace(speed: Double, style: PaceStyle) -> String {
        guard let value = style.paceValue(speed: speed) else { return "—" }
        return paceValue(value, style: style) + " " + paceUnit(style)
    }

    /// A value from `PaceStyle.paceValue(speed:)` without its unit: "5'24\"" or "24.3".
    static func paceValue(_ value: Double, style: PaceStyle) -> String {
        switch style {
        case .minutesPerKilometer, .minutesPer100Meters: minutesSeconds(value)
        case .kilometersPerHour: String(format: "%.1f", value)
        }
    }

    static func paceUnit(_ style: PaceStyle) -> String {
        switch style {
        case .minutesPerKilometer: "/km"
        case .kilometersPerHour: "km/h"
        case .minutesPer100Meters: "/100m"
        }
    }

    static func elevation(_ meters: Double) -> String {
        "\(Int(meters.rounded())) m"
    }

    static func heartRate(_ bpm: Double) -> String {
        "\(Int(bpm.rounded())) bpm"
    }

    static func energy(_ kcal: Double) -> String {
        "\(Int(kcal.rounded())) kcal"
    }

    private static func minutesSeconds(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d'%02d\"", total / 60, total % 60)
    }
}

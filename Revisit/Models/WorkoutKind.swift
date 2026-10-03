import Foundation

/// The workout types Revisit imports. Outdoor ones carry a GPS route; indoor ones and
/// pool swims don't, but can still be viewed and exported.
nonisolated enum WorkoutKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case running
    case walking
    case hiking
    case cycling
    case openWaterSwimming
    case poolSwimming

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .running: "跑步"
        case .walking: "走路"
        case .hiking: "健行"
        case .cycling: "騎車"
        case .openWaterSwimming: "開放水域游泳"
        case .poolSwimming: "泳池游泳"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling: "figure.outdoor.cycle"
        case .openWaterSwimming: "figure.open.water.swim"
        case .poolSwimming: "figure.pool.swim"
        }
    }

    var paceStyle: PaceStyle {
        switch self {
        case .running, .walking, .hiking: .minutesPerKilometer
        case .cycling: .kilometersPerHour
        case .openWaterSwimming, .poolSwimming: .minutesPer100Meters
        }
    }

    /// Anything faster than this between two GPS points is treated as a GPS glitch (m/s).
    var maxPlausibleSpeed: Double {
        switch self {
        case .running: 12
        case .walking, .hiking: 6
        case .cycling: 30
        case .openWaterSwimming, .poolSwimming: 4
        }
    }
}

nonisolated enum PaceStyle: Sendable {
    case minutesPerKilometer
    case kilometersPerHour
    case minutesPer100Meters
}

nonisolated enum RouteStatus: String, Codable, Sendable {
    /// Imported from HealthKit, route not fetched yet.
    case pending
    case ready
    /// The workout has no GPS route (indoor, pool, GPS off, or too few valid points).
    case none
    case failed
}

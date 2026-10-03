import Foundation
@testable import Revisit

/// Builders for synthetic routes used across tests.
enum TestRoutes {
    static let origin = Coordinate(latitude: 25.03, longitude: 121.53)
    static let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// A straight line heading east at `speed` m/s, one fix per second.
    static func straightLine(
        seconds: Int,
        speed: Double = 3,
        altitude: (Int) -> Double = { _ in 10 },
        startOffset: TimeInterval = 0,
        from origin: Coordinate = origin
    ) -> [RawLocation] {
        (0...seconds).map { second in
            let point = Geo.offset(origin, north: 0, east: Double(second) * speed)
            return RawLocation(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: altitude(second),
                timestamp: start + startOffset + TimeInterval(second),
                speed: speed,
                horizontalAccuracy: 5
            )
        }
    }
}

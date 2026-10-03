import Foundation

nonisolated enum Geo {
    /// Mean Earth radius (IUGG), meters.
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in meters (haversine).
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude).radians
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b` in degrees, 0..<360, clockwise from north.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let dLon = (b.longitude - a.longitude).radians
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x).degrees
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Linear interpolation; accurate enough for points a few meters apart.
    static func interpolate(_ a: Coordinate, _ b: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
    }

    /// Moves `origin` by the given meters north/east (flat-earth approximation).
    static func offset(_ origin: Coordinate, north: Double, east: Double) -> Coordinate {
        let dLat = (north / earthRadius).degrees
        let dLon = (east / (earthRadius * cos(origin.latitude.radians))).degrees
        return Coordinate(latitude: origin.latitude + dLat, longitude: origin.longitude + dLon)
    }

    static func boundingBox(of coordinates: [Coordinate]) -> BoundingBox? {
        guard let first = coordinates.first else { return nil }
        var box = BoundingBox(minLatitude: first.latitude, maxLatitude: first.latitude,
                              minLongitude: first.longitude, maxLongitude: first.longitude)
        for c in coordinates.dropFirst() {
            box.minLatitude = min(box.minLatitude, c.latitude)
            box.maxLatitude = max(box.maxLatitude, c.latitude)
            box.minLongitude = min(box.minLongitude, c.longitude)
            box.maxLongitude = max(box.maxLongitude, c.longitude)
        }
        return box
    }
}

nonisolated struct BoundingBox: Equatable, Sendable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    var center: Coordinate {
        Coordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }
}

nonisolated extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

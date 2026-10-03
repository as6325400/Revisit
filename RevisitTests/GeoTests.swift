import Foundation
import Testing
@testable import Revisit

struct GeoTests {
    @Test func oneDegreeOfLatitudeIsAbout111Kilometers() {
        let a = Coordinate(latitude: 25, longitude: 121)
        let b = Coordinate(latitude: 26, longitude: 121)
        #expect(abs(Geo.distance(a, b) - 111_195) < 1)
    }

    @Test func distanceToSelfIsZero() {
        #expect(Geo.distance(TestRoutes.origin, TestRoutes.origin) == 0)
    }

    @Test func bearingPointsNorthAndEast() {
        let origin = TestRoutes.origin
        #expect(abs(Geo.bearing(from: origin, to: Geo.offset(origin, north: 100, east: 0))) < 0.01)
        #expect(abs(Geo.bearing(from: origin, to: Geo.offset(origin, north: 0, east: 100)) - 90) < 0.01)
        #expect(abs(Geo.bearing(from: origin, to: Geo.offset(origin, north: -100, east: 0)) - 180) < 0.01)
    }

    @Test func offsetMovesByTheRequestedMeters() {
        let moved = Geo.offset(TestRoutes.origin, north: 300, east: 400)
        #expect(abs(Geo.distance(TestRoutes.origin, moved) - 500) < 0.5)
    }

    @Test func boundingBoxCoversAllPoints() {
        let points = [
            Coordinate(latitude: 25.0, longitude: 121.5),
            Coordinate(latitude: 25.2, longitude: 121.4),
            Coordinate(latitude: 24.9, longitude: 121.6),
        ]
        let box = Geo.boundingBox(of: points)
        #expect(box == BoundingBox(minLatitude: 24.9, maxLatitude: 25.2, minLongitude: 121.4, maxLongitude: 121.6))
        #expect(Geo.boundingBox(of: []) == nil)
    }
}

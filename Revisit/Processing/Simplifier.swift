import Foundation

nonisolated enum Simplifier {
    /// Douglas–Peucker simplification. `tolerance` is in meters.
    static func simplify(_ coordinates: [Coordinate], tolerance: Double) -> [Coordinate] {
        guard coordinates.count > 2 else { return coordinates }

        // Project to a local flat plane (meters) around the first point.
        let origin = coordinates[0]
        let metersPerDegreeLat = Geo.earthRadius * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLat * cos(origin.latitude.radians)
        let points = coordinates.map {
            (x: ($0.longitude - origin.longitude) * metersPerDegreeLon,
             y: ($0.latitude - origin.latitude) * metersPerDegreeLat)
        }

        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy

            var maxDistance = 0.0
            var maxIndex = start
            for i in (start + 1)..<end {
                let p = points[i]
                let distance: Double
                if lengthSquared == 0 {
                    distance = hypot(p.x - a.x, p.y - a.y)
                } else {
                    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
                    distance = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                }
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = i
                }
            }

            if maxDistance > tolerance {
                keep[maxIndex] = true
                stack.append((start, maxIndex))
                stack.append((maxIndex, end))
            }
        }

        return coordinates.indices.filter { keep[$0] }.map { coordinates[$0] }
    }

    /// Simplifies with a growing tolerance until at most `maxPoints` remain.
    static func simplify(_ coordinates: [Coordinate], maxPoints: Int, initialTolerance: Double = 2) -> [Coordinate] {
        var tolerance = initialTolerance
        var result = simplify(coordinates, tolerance: tolerance)
        while result.count > maxPoints && tolerance < 10_000 {
            tolerance *= 2
            result = simplify(coordinates, tolerance: tolerance)
        }
        return result
    }
}

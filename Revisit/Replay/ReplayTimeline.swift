import Foundation

/// Maps replay progress (0...1) to a position on the track. Uses moving time, so pauses
/// don't stall the replay and faster stretches go by faster, like the real workout.
nonisolated struct ReplayTimeline: Sendable {
    struct Position: Equatable, Sendable {
        var coordinate: Coordinate
        /// Track index at or just before this position.
        var index: Int
        /// Meters along the route.
        var distance: Double
        /// Seconds of moving time since the start.
        var movingTime: Double
    }

    let track: ProcessedTrack
    /// Moving time at each track point, with the gaps between segments removed.
    let movingTimes: [Double]

    var totalMovingTime: Double { movingTimes.last ?? 0 }
    var totalDistance: Double { track.totalDistance }

    init(track: ProcessedTrack) {
        self.track = track
        var times: [Double] = []
        times.reserveCapacity(track.count)
        for segment in track.segments {
            let base = times.last ?? 0
            let segmentStart = track.times[segment.lowerBound]
            for index in segment {
                times.append(base + track.times[index] - segmentStart)
            }
        }
        movingTimes = times
    }

    func position(atProgress progress: Double) -> Position {
        guard !track.isEmpty else {
            return Position(coordinate: Coordinate(latitude: 0, longitude: 0), index: 0, distance: 0, movingTime: 0)
        }
        let target = min(1, max(0, progress)) * totalMovingTime
        let index = Self.lastIndex(in: movingTimes, notAbove: target)
        guard index < track.count - 1 else {
            return Position(coordinate: track.coordinate(at: index), index: index, distance: track.distances[index], movingTime: movingTimes[index])
        }
        let span = movingTimes[index + 1] - movingTimes[index]
        let t = span > 0 ? (target - movingTimes[index]) / span : 0
        return Position(
            coordinate: Geo.interpolate(track.coordinate(at: index), track.coordinate(at: index + 1), fraction: t),
            index: index,
            distance: track.distances[index] + (track.distances[index + 1] - track.distances[index]) * t,
            movingTime: target
        )
    }

    /// The point `meters` along the route, clamped to the route's ends.
    func coordinate(atDistance meters: Double) -> Coordinate {
        guard !track.isEmpty else { return Coordinate(latitude: 0, longitude: 0) }
        let target = min(max(0, meters), totalDistance)
        let index = Self.lastIndex(in: track.distances, notAbove: target)
        guard index < track.count - 1 else { return track.coordinate(at: index) }
        let span = track.distances[index + 1] - track.distances[index]
        let t = span > 0 ? (target - track.distances[index]) / span : 0
        return Geo.interpolate(track.coordinate(at: index), track.coordinate(at: index + 1), fraction: t)
    }

    /// Binary search: the last index whose value is <= `target` (values ascending).
    static func lastIndex(in values: [Double], notAbove target: Double) -> Int {
        var low = 0
        var high = values.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if values[mid] <= target {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}

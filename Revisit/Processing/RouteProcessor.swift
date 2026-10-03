import Foundation

/// Turns raw HealthKit route locations into a clean `ProcessedTrack`.
nonisolated struct RouteProcessor: Sendable {
    struct Options: Sendable {
        /// Points less accurate than this (meters) are dropped.
        var maxHorizontalAccuracy: Double = 50
        /// Implied speeds above this (m/s) are treated as GPS jumps.
        var maxSpeed: Double = 12
        /// A time gap longer than this (seconds) starts a new segment (a pause).
        var segmentGap: TimeInterval = 15
        /// After this many consecutive rejected jumps, accept the point as a new segment
        /// so one bad anchor point can't swallow the rest of the route.
        var maxConsecutiveJumps: Int = 5
        var altitudeSmoothingWindow: Int = 7
        var speedSmoothingWindow: Int = 5
        /// Altitude must move this far (meters) before it counts toward elevation gain.
        var elevationThreshold: Double = 3
        /// Heart rate is left unknown if the nearest sample is further away than this (seconds).
        var maxHeartRateGap: TimeInterval = 30
    }

    var options: Options

    init(options: Options = Options()) {
        self.options = options
    }

    init(kind: WorkoutKind) {
        var options = Options()
        options.maxSpeed = kind.maxPlausibleSpeed
        self.init(options: options)
    }

    func process(locations: [RawLocation], heartRates: [HeartRateSample], workoutStart: Date) -> ProcessedTrack {
        let kept = filter(locations)
        guard kept.count >= 2 else { return ProcessedTrack() }

        var track = ProcessedTrack()
        track.latitudes.reserveCapacity(kept.count)
        var rawAltitudes: [Double] = []
        var rawSpeeds: [Double] = []
        var distance = 0.0

        for (index, point) in kept.enumerated() {
            let isSegmentStart = index == 0 || point.timestamp.timeIntervalSince(kept[index - 1].timestamp) > options.segmentGap
            var derivedSpeed = 0.0
            if isSegmentStart {
                track.segmentStarts.append(index)
            } else {
                let previous = kept[index - 1]
                let step = Geo.distance(previous.coordinate, point.coordinate)
                distance += step
                let dt = point.timestamp.timeIntervalSince(previous.timestamp)
                derivedSpeed = dt > 0 ? step / dt : 0
            }
            track.latitudes.append(point.latitude)
            track.longitudes.append(point.longitude)
            track.times.append(point.timestamp.timeIntervalSince(workoutStart))
            track.distances.append(distance)
            rawAltitudes.append(point.altitude)
            rawSpeeds.append(point.speed >= 0 ? point.speed : derivedSpeed)
        }

        let segments = track.segments
        track.altitudes = Self.smoothed(rawAltitudes, window: options.altitudeSmoothingWindow, segments: segments)
        track.speeds = Self.smoothed(rawSpeeds, window: options.speedSmoothingWindow, segments: segments)
        track.elevationGain = Self.elevationGain(track.altitudes, segments: segments, threshold: options.elevationThreshold)
        track.heartRates = Self.interpolateHeartRates(
            at: kept.map(\.timestamp),
            samples: heartRates,
            maxGap: options.maxHeartRateGap
        )
        return track
    }

    /// Drops inaccurate, duplicate and jumping points; returns them sorted by time.
    func filter(_ locations: [RawLocation]) -> [RawLocation] {
        let sorted = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= options.maxHorizontalAccuracy }
            .sorted { $0.timestamp < $1.timestamp }

        var kept: [RawLocation] = []
        kept.reserveCapacity(sorted.count)
        var consecutiveJumps = 0

        for point in sorted {
            guard let last = kept.last else {
                kept.append(point)
                continue
            }
            let dt = point.timestamp.timeIntervalSince(last.timestamp)
            if dt <= 0 { continue }

            let isGap = dt > options.segmentGap
            let impliedSpeed = Geo.distance(last.coordinate, point.coordinate) / dt
            if !isGap && impliedSpeed > options.maxSpeed && consecutiveJumps < options.maxConsecutiveJumps {
                consecutiveJumps += 1
                continue
            }
            consecutiveJumps = 0
            kept.append(point)
        }
        return kept
    }

    /// Centered moving average that never mixes values across segments.
    static func smoothed(_ values: [Double], window: Int, segments: [Range<Int>]) -> [Double] {
        guard window > 1 else { return values }
        var result = values
        let half = window / 2
        for segment in segments {
            for i in segment {
                let lower = max(segment.lowerBound, i - half)
                let upper = min(segment.upperBound - 1, i + half)
                var sum = 0.0
                for j in lower...upper { sum += values[j] }
                result[i] = sum / Double(upper - lower + 1)
            }
        }
        return result
    }

    /// Total climb, ignoring wiggles smaller than `threshold` (hysteresis).
    static func elevationGain(_ altitudes: [Double], segments: [Range<Int>], threshold: Double) -> Double {
        var gain = 0.0
        for segment in segments {
            guard var reference = segment.first.map({ altitudes[$0] }) else { continue }
            for i in segment.dropFirst() {
                let delta = altitudes[i] - reference
                if delta >= threshold {
                    gain += delta
                    reference = altitudes[i]
                } else if delta <= -threshold {
                    reference = altitudes[i]
                }
            }
        }
        return gain
    }

    /// Heart rate at each date by linear interpolation between the surrounding samples.
    static func interpolateHeartRates(at dates: [Date], samples: [HeartRateSample], maxGap: TimeInterval) -> [Double] {
        let samples = samples.sorted { $0.date < $1.date }
        guard !samples.isEmpty else { return Array(repeating: ProcessedTrack.unknownHeartRate, count: dates.count) }

        var result: [Double] = []
        result.reserveCapacity(dates.count)
        var upper = 0
        for date in dates {
            while upper < samples.count && samples[upper].date < date { upper += 1 }
            let after = upper < samples.count ? samples[upper] : nil
            let before = upper > 0 ? samples[upper - 1] : nil

            switch (before, after) {
            case let (before?, after?):
                let span = after.date.timeIntervalSince(before.date)
                let toBefore = date.timeIntervalSince(before.date)
                let toAfter = after.date.timeIntervalSince(date)
                if span > 0 && span <= maxGap * 2 {
                    result.append(before.bpm + (after.bpm - before.bpm) * toBefore / span)
                } else if min(toBefore, toAfter) <= maxGap {
                    result.append(toBefore <= toAfter ? before.bpm : after.bpm)
                } else {
                    result.append(ProcessedTrack.unknownHeartRate)
                }
            case let (sample?, nil), let (nil, sample?):
                let gap = abs(date.timeIntervalSince(sample.date))
                result.append(gap <= maxGap ? sample.bpm : ProcessedTrack.unknownHeartRate)
            case (nil, nil):
                result.append(ProcessedTrack.unknownHeartRate)
            }
        }
        return result
    }
}

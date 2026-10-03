import Foundation

/// Raw workout data as read from HealthKit, free of HealthKit types so it can be unit tested.
nonisolated struct WorkoutExportInput: Sendable {
    /// A HealthKit quantity sample covering an interval, e.g. 12.3 m of distance.
    struct IntervalSample: Equatable, Sendable {
        var start: Date
        var end: Date
        var value: Double
    }

    /// A pool length as recorded by Apple Watch (an `HKWorkoutEvent` of type `.lap`).
    struct SwimLap: Equatable, Sendable {
        var interval: DateInterval
        var stroke: FITSwimStroke?
    }

    var workoutID: UUID
    var kind: WorkoutKind
    var isIndoor: Bool
    var start: Date
    var end: Date
    /// Moving time from HealthKit (pauses excluded).
    var duration: TimeInterval
    var pauses: [DateInterval] = []
    var locations: [RawLocation] = []
    var heartRates: [HeartRateSample] = []
    var distanceSamples: [IntervalSample] = []
    var strokeSamples: [IntervalSample] = []
    var swimLaps: [SwimLap] = []
    var poolLength: Double?
    var totalDistance: Double?
    var activeEnergy: Double?
    var elevationAscended: Double?
    var elevationDescended: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var utcOffset: Int = 0
}

/// Turns raw workout data into a `FITActivity`.
nonisolated enum FITActivityBuilder {
    /// Rests shorter than this between pool lengths aren't written as idle lengths.
    static let minimumRest: TimeInterval = 5

    static func build(_ input: WorkoutExportInput) -> FITActivity {
        let records = makeRecords(input)
        let lengths = input.kind == .poolSwimming ? makeLengths(input) : []
        let strokes = input.strokeSamples.isEmpty ? nil : Int(input.strokeSamples.reduce(0) { $0 + $1.value }.rounded())
        let distance = input.totalDistance ?? records.last(where: { $0.distance != nil })?.distance
        let heartRates = input.heartRates.map(\.bpm)

        var activity = FITActivity(
            sport: FITSport.of(input.kind, indoor: input.isIndoor),
            start: input.start,
            end: input.end,
            timerTime: input.duration
        )
        activity.pauses = input.pauses
        activity.records = records
        activity.lengths = lengths
        activity.poolLength = input.kind == .poolSwimming ? input.poolLength : nil
        activity.totalDistance = distance
        activity.totalCalories = input.activeEnergy
        activity.totalAscent = input.elevationAscended
        activity.totalDescent = input.elevationDescended
        activity.averageHeartRate = input.averageHeartRate ?? (heartRates.isEmpty ? nil : heartRates.reduce(0, +) / Double(heartRates.count))
        activity.maxHeartRate = input.maxHeartRate ?? heartRates.max()
        activity.totalStrokes = strokes
        activity.maxSpeed = records.compactMap(\.speed).filter { $0 <= input.kind.maxPlausibleSpeed }.max()
        activity.utcOffset = input.utcOffset
        activity.serialNumber = serialNumber(for: input.workoutID)
        return activity
    }

    // MARK: Records

    static func makeRecords(_ input: WorkoutExportInput) -> [FITActivity.Record] {
        let locations = input.locations
            .filter { $0.horizontalAccuracy >= 0 }
            .sorted { $0.timestamp < $1.timestamp }

        if !locations.isEmpty {
            let times = locations.map(\.timestamp)
            let heartRates = RouteProcessor.interpolateHeartRates(at: times, samples: input.heartRates, maxGap: 30)
            let distances = input.distanceSamples.isEmpty
                ? gpsDistances(locations, pauses: input.pauses)
                : cumulative(input.distanceSamples, at: times)
            return locations.indices.map { index in
                let location = locations[index]
                return FITActivity.Record(
                    timestamp: location.timestamp,
                    coordinate: location.coordinate,
                    altitude: location.altitude,
                    heartRate: heartRates[index] >= 0 ? heartRates[index] : nil,
                    distance: distances[index],
                    speed: location.speed >= 0 ? location.speed : nil
                )
            }
        }

        // No route (indoor, pool): a record at every heart rate and distance sample.
        let times = Array(Set(input.heartRates.map(\.date) + input.distanceSamples.map(\.end)))
            .filter { $0 >= input.start && $0 <= input.end }
            .sorted()
        guard !times.isEmpty else { return [] }
        let heartRates = RouteProcessor.interpolateHeartRates(at: times, samples: input.heartRates, maxGap: 30)
        let distances: [Double?] = input.distanceSamples.isEmpty
            ? Array(repeating: nil, count: times.count)
            : cumulative(input.distanceSamples, at: times)
        let speeds = derivedSpeeds(times: times, distances: distances, window: 10)
        return times.indices.map { index in
            FITActivity.Record(
                timestamp: times[index],
                heartRate: heartRates[index] >= 0 ? heartRates[index] : nil,
                distance: distances[index],
                speed: speeds[index]
            )
        }
    }

    /// Distance covered by interval samples up to each time, prorating a sample in progress.
    static func cumulative(_ samples: [WorkoutExportInput.IntervalSample], at times: [Date]) -> [Double?] {
        let samples = samples.sorted { $0.start < $1.start }
        var completed = 0.0
        var next = 0
        return times.map { time in
            while next < samples.count, samples[next].end <= time {
                completed += samples[next].value
                next += 1
            }
            var total = completed
            if next < samples.count, samples[next].start < time {
                let sample = samples[next]
                let span = sample.end.timeIntervalSince(sample.start)
                if span > 0 { total += sample.value * time.timeIntervalSince(sample.start) / span }
            }
            return total
        }
    }

    /// Cumulative GPS distance, not counting jumps across pauses.
    static func gpsDistances(_ locations: [RawLocation], pauses: [DateInterval]) -> [Double?] {
        var total = 0.0
        var result: [Double?] = []
        for (index, location) in locations.enumerated() {
            if index > 0 {
                let previous = locations[index - 1]
                let crossesPause = pauses.contains { $0.start >= previous.timestamp && $0.start < location.timestamp }
                if !crossesPause {
                    total += Geo.distance(previous.coordinate, location.coordinate)
                }
            }
            result.append(total)
        }
        return result
    }

    /// Speed from the change in distance over roughly `window` seconds around each point.
    static func derivedSpeeds(times: [Date], distances: [Double?], window: TimeInterval) -> [Double?] {
        times.indices.map { index in
            guard distances[index] != nil else { return nil }
            var lower = index
            var upper = index
            while lower > 0, times[index].timeIntervalSince(times[lower - 1]) <= window / 2, distances[lower - 1] != nil { lower -= 1 }
            while upper < times.count - 1, times[upper + 1].timeIntervalSince(times[index]) <= window / 2, distances[upper + 1] != nil { upper += 1 }
            let span = times[upper].timeIntervalSince(times[lower])
            guard span > 0, let from = distances[lower], let to = distances[upper] else { return nil }
            return max(0, (to - from) / span)
        }
    }

    // MARK: Pool lengths

    /// Active lengths from the Watch's lap events, with idle lengths for the rests between them.
    static func makeLengths(_ input: WorkoutExportInput) -> [FITActivity.Length] {
        let laps = input.swimLaps.sorted { $0.interval.start < $1.interval.start }
        var lengths: [FITActivity.Length] = []
        var previousEnd = input.start
        for lap in laps {
            if lap.interval.start.timeIntervalSince(previousEnd) >= minimumRest {
                lengths.append(FITActivity.Length(start: previousEnd, end: lap.interval.start, isActive: false))
            }
            let strokes = input.strokeSamples
                .filter { $0.start >= lap.interval.start && $0.end <= lap.interval.end.addingTimeInterval(1) }
                .reduce(0) { $0 + $1.value }
            lengths.append(FITActivity.Length(
                start: lap.interval.start,
                end: lap.interval.end,
                isActive: true,
                strokes: strokes > 0 ? Int(strokes.rounded()) : nil,
                stroke: lap.stroke
            ))
            previousEnd = lap.interval.end
        }
        return lengths
    }

    /// A non-zero 32-bit number derived from the workout ID.
    static func serialNumber(for id: UUID) -> UInt32 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return value == 0 ? 1 : value
    }
}

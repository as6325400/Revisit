#if DEBUG
import CoreLocation
import HealthKit

/// Writes a few realistic-looking workouts with routes into Health, so the simulator
/// (which has no Apple Watch) has something to show. Debug builds only.
enum SampleDataSeeder {
    static func seed(using health: HealthKitService) async throws -> Int {
        try await health.requestAuthorization()
        let workouts = SampleRoutes.all(endingBefore: .now)
        for workout in workouts {
            try await save(workout, to: health.store)
        }
        return workouts.count
    }

    private static func save(_ sample: SampleWorkout, to store: HKHealthStore) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sample.kind.activityType
        configuration.locationType = sample.locations.isEmpty ? .indoor : .outdoor
        if sample.kind == .openWaterSwimming {
            configuration.swimmingLocationType = .openWater
        }
        if sample.kind == .poolSwimming, let poolLength = sample.poolLength {
            configuration.swimmingLocationType = .pool
            configuration.lapLength = HKQuantity(unit: .meter(), doubleValue: poolLength)
        }

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: sample.start)

        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = [
            HKQuantitySample(
                type: HKQuantityType(.activeEnergyBurned),
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: sample.activeEnergy),
                start: sample.start, end: sample.end
            ),
        ]
        if sample.distanceSamples.isEmpty {
            samples.append(HKQuantitySample(
                type: sample.kind.distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: sample.distance),
                start: sample.start, end: sample.end
            ))
        } else {
            samples += sample.distanceSamples.map {
                HKQuantitySample(type: sample.kind.distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: $0.value), start: $0.start, end: $0.end)
            }
        }
        samples += sample.strokeSamples.map {
            HKQuantitySample(type: HKQuantityType(.swimmingStrokeCount), quantity: HKQuantity(unit: .count(), doubleValue: $0.value), start: $0.start, end: $0.end)
        }
        samples += sample.heartRates.map {
            HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: bpm, doubleValue: $0.bpm),
                start: $0.date, end: $0.date
            )
        }
        try await builder.addSamples(samples)

        if !sample.swimLaps.isEmpty {
            try await builder.addWorkoutEvents(sample.swimLaps.map { lap in
                HKWorkoutEvent(type: .lap, dateInterval: lap.interval, metadata: [
                    HKMetadataKeySwimmingStrokeStyle: (lap.stroke == .breaststroke ? HKSwimmingStrokeStyle.breaststroke : .freestyle).rawValue,
                ])
            })
        }

        var metadata: [String: Any] = [
            HKMetadataKeyIndoorWorkout: sample.isIndoor,
            HKMetadataKeyElevationAscended: HKQuantity(unit: .meter(), doubleValue: sample.elevationGain),
        ]
        if sample.kind == .openWaterSwimming {
            metadata[HKMetadataKeySwimmingLocationType] = HKWorkoutSwimmingLocationType.openWater.rawValue
        }
        if sample.kind == .poolSwimming {
            metadata[HKMetadataKeySwimmingLocationType] = HKWorkoutSwimmingLocationType.pool.rawValue
            if let poolLength = sample.poolLength {
                metadata[HKMetadataKeyLapLength] = HKQuantity(unit: .meter(), doubleValue: poolLength)
            }
        }
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: sample.end)
        guard let workout = try await builder.finishWorkout(), !sample.locations.isEmpty else { return }

        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(sample.locations.map {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                altitude: $0.altitude,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: 4,
                course: -1,
                speed: $0.speed,
                timestamp: $0.timestamp
            )
        })
        _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
    }
}

struct SampleWorkout {
    var kind: WorkoutKind
    var start: Date
    var end: Date
    var isIndoor = false
    var locations: [RawLocation] = []
    var heartRates: [HeartRateSample] = []
    var distance: Double
    var activeEnergy: Double
    var elevationGain: Double = 0
    var distanceSamples: [WorkoutExportInput.IntervalSample] = []
    var strokeSamples: [WorkoutExportInput.IntervalSample] = []
    var swimLaps: [WorkoutExportInput.SwimLap] = []
    var poolLength: Double?
}

/// Procedurally generated routes around Taiwan.
enum SampleRoutes {
    static func all(endingBefore now: Date) -> [SampleWorkout] {
        let hour: TimeInterval = 3600
        let day: TimeInterval = 24 * hour
        return [
            // 大安森林公園 3 laps
            make(
                kind: .running,
                waypoints: ellipse(center: Coordinate(latitude: 25.0299, longitude: 121.5358), northRadius: 300, eastRadius: 240, laps: 3),
                speed: 3.0, start: now - 2 * hour, altitude: { 12 + 2 * sin($0 * .pi * 6) },
                heartRate: { 145 + 12 * $0 }, energyPerKm: 65
            ),
            // 象山步道 out and back
            make(
                kind: .hiking,
                waypoints: outAndBack([
                    Coordinate(latitude: 25.0322, longitude: 121.5705),
                    Coordinate(latitude: 25.0300, longitude: 121.5722),
                    Coordinate(latitude: 25.0283, longitude: 121.5744),
                    Coordinate(latitude: 25.0272, longitude: 121.5763),
                ]),
                speed: 0.9, start: now - 1 * day - 3 * hour, altitude: { 40 + 143 * sin($0 * .pi) },
                heartRate: { 115 + 35 * sin($0 * .pi) }, energyPerKm: 90
            ),
            // 基隆河左岸自行車道
            make(
                kind: .cycling,
                waypoints: [
                    Coordinate(latitude: 25.0713, longitude: 121.5153),
                    Coordinate(latitude: 25.0793, longitude: 121.5262),
                    Coordinate(latitude: 25.0822, longitude: 121.5400),
                    Coordinate(latitude: 25.0781, longitude: 121.5546),
                    Coordinate(latitude: 25.0716, longitude: 121.5700),
                    Coordinate(latitude: 25.0651, longitude: 121.5862),
                    Coordinate(latitude: 25.0619, longitude: 121.6031),
                ],
                speed: 6.5, start: now - 3 * day - 5 * hour, altitude: { 8 + 3 * sin($0 * .pi * 4) },
                heartRate: { 128 + 10 * sin($0 * .pi * 3) }, energyPerKm: 25
            ),
            // 日月潭 朝霧碼頭 → 伊達邵 (open water)
            make(
                kind: .openWaterSwimming,
                waypoints: [
                    Coordinate(latitude: 23.8641, longitude: 120.9219),
                    Coordinate(latitude: 23.8575, longitude: 120.9255),
                    Coordinate(latitude: 23.8519, longitude: 120.9284),
                ],
                speed: 0.85, start: now - 6 * day - 2 * hour, altitude: { _ in 748 },
                heartRate: { 135 + 8 * $0 }, energyPerKm: 240, wobbleMeters: 6
            ),
            treadmillRun(start: now - 4 * day - 3 * hour),
            poolSwim(start: now - 5 * day - 4 * hour),
        ]
    }

    /// 35 minutes on a treadmill: distance samples every 10 s, no route.
    static func treadmillRun(start: Date) -> SampleWorkout {
        let seconds = 35 * 60
        var generator = SeededGenerator(seed: 42)
        var distanceSamples: [WorkoutExportInput.IntervalSample] = []
        var total = 0.0
        for t in stride(from: 0, to: seconds, by: 10) {
            let speed = 3.0 + 0.3 * sin(Double(t) / 300)
            distanceSamples.append(.init(start: start + TimeInterval(t), end: start + TimeInterval(t + 10), value: speed * 10))
            total += speed * 10
        }
        let heartRates = stride(from: 0, through: seconds, by: 5).map { t in
            HeartRateSample(date: start + TimeInterval(t), bpm: 140 + 15 * Double(t) / Double(seconds) + Double.random(in: -2...2, using: &generator))
        }
        return SampleWorkout(
            kind: .running, start: start, end: start + TimeInterval(seconds), isIndoor: true,
            heartRates: heartRates, distance: total, activeEnergy: total / 1000 * 65,
            distanceSamples: distanceSamples
        )
    }

    /// 1000 m in a 25 m pool: 10 sets of 4 lengths with 20 s rests, set 7 breaststroke.
    static func poolSwim(start: Date) -> SampleWorkout {
        let poolLength = 25.0
        var generator = SeededGenerator(seed: 7)
        var laps: [WorkoutExportInput.SwimLap] = []
        var distanceSamples: [WorkoutExportInput.IntervalSample] = []
        var strokeSamples: [WorkoutExportInput.IntervalSample] = []
        var time = start + 10
        for set in 0..<10 {
            let stroke: FITSwimStroke = set == 6 ? .breaststroke : .freestyle
            for _ in 0..<4 {
                let duration = (stroke == .breaststroke ? 36 : 29) + Double.random(in: -2...2, using: &generator)
                let interval = DateInterval(start: time, duration: duration)
                laps.append(.init(interval: interval, stroke: stroke))
                distanceSamples.append(.init(start: interval.start, end: interval.end, value: poolLength))
                strokeSamples.append(.init(start: interval.start, end: interval.end, value: Double(Int.random(in: 15...19, using: &generator))))
                time = interval.end + 1
            }
            time += 20
        }
        let end = time
        let heartRates = stride(from: 0.0, through: end.timeIntervalSince(start), by: 5).map { t in
            HeartRateSample(date: start + t, bpm: 128 + 10 * sin(t / 120) + Double.random(in: -2...2, using: &generator))
        }
        return SampleWorkout(
            kind: .poolSwimming, start: start, end: end,
            heartRates: heartRates, distance: Double(laps.count) * poolLength, activeEnergy: 260,
            distanceSamples: distanceSamples, strokeSamples: strokeSamples, swimLaps: laps, poolLength: poolLength
        )
    }

    // MARK: - Generation

    private static func make(
        kind: WorkoutKind,
        waypoints: [Coordinate],
        speed: Double,
        start: Date,
        altitude: (Double) -> Double,
        heartRate: (Double) -> Double,
        energyPerKm: Double,
        wobbleMeters: Double = 2
    ) -> SampleWorkout {
        let legs = zip(waypoints, waypoints.dropFirst()).map { (from: $0, to: $1, length: Geo.distance($0, $1)) }
        let total = legs.reduce(0) { $0 + $1.length }
        let seconds = Int(total / speed)

        var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(start.timeIntervalSince1970)))
        var locations: [RawLocation] = []
        var elevationGain = 0.0
        var previousAltitude = altitude(0)
        var legIndex = 0
        var legStart = 0.0
        let phase = Double.random(in: 0...(2 * .pi), using: &generator)

        for second in 0...seconds {
            let traveled = min(Double(second) * speed, total)
            while legIndex < legs.count - 1 && traveled > legStart + legs[legIndex].length {
                legStart += legs[legIndex].length
                legIndex += 1
            }
            let leg = legs[legIndex]
            let fraction = leg.length > 0 ? (traveled - legStart) / leg.length : 0
            let progress = total > 0 ? traveled / total : 0
            let smoothAltitude = altitude(progress)
            elevationGain += max(0, smoothAltitude - previousAltitude)
            previousAltitude = smoothAltitude
            // Slow, smooth drift like real GPS error, not per-second jitter (which would inflate distance).
            let t = Double(second)
            let point = Geo.offset(
                Geo.interpolate(leg.from, leg.to, fraction: fraction),
                north: wobbleMeters * sin(t / 37 + phase),
                east: wobbleMeters * cos(t / 53 + phase)
            )
            locations.append(RawLocation(
                latitude: point.latitude,
                longitude: point.longitude,
                altitude: smoothAltitude + Double.random(in: -0.5...0.5, using: &generator),
                timestamp: start + TimeInterval(second),
                // Pace drifts over minutes (hills, tiredness) plus a little jitter.
                speed: speed * (1 + 0.1 * sin(t / 180 + phase)) * Double.random(in: 0.97...1.03, using: &generator),
                horizontalAccuracy: 5
            ))
        }

        let heartRates = stride(from: 0, through: seconds, by: 5).map { second in
            let progress = Double(second) / Double(max(seconds, 1))
            return HeartRateSample(
                date: start + TimeInterval(second),
                bpm: heartRate(progress) + Double.random(in: -3...3, using: &generator)
            )
        }

        return SampleWorkout(
            kind: kind,
            start: start,
            end: start + TimeInterval(seconds),
            locations: locations,
            heartRates: heartRates,
            distance: total,
            activeEnergy: total / 1000 * energyPerKm,
            elevationGain: elevationGain
        )
    }

    private static func ellipse(center: Coordinate, northRadius: Double, eastRadius: Double, laps: Int) -> [Coordinate] {
        let steps = 48
        return (0...(steps * laps)).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            return Geo.offset(center, north: northRadius * cos(angle), east: eastRadius * sin(angle))
        }
    }

    private static func outAndBack(_ waypoints: [Coordinate]) -> [Coordinate] {
        waypoints + waypoints.reversed().dropFirst()
    }
}

/// Deterministic RNG so the sample routes look the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}
#endif

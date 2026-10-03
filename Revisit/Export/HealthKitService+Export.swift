import HealthKit

extension HealthKitService {
    /// Everything a FIT export needs, read raw from HealthKit (not the smoothed cache).
    func exportInput(for workout: HKWorkout, kind: WorkoutKind, isIndoor: Bool) async throws -> WorkoutExportInput {
        let metadata = workout.metadata ?? [:]
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
        let timeZone = (metadata[HKMetadataKeyTimeZone] as? String).flatMap(TimeZone.init(identifier:)) ?? .current

        var input = WorkoutExportInput(
            workoutID: workout.uuid,
            kind: kind,
            isIndoor: isIndoor,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration
        )
        input.pauses = Self.pauses(in: workout)
        input.locations = try await routeLocations(for: workout)
        input.heartRates = try await heartRates(for: workout)
        input.distanceSamples = try await intervalSamples(of: kind.distanceType, unit: .meter(), during: workout)
        if kind == .openWaterSwimming || kind == .poolSwimming {
            input.strokeSamples = try await intervalSamples(of: HKQuantityType(.swimmingStrokeCount), unit: .count(), during: workout)
        }
        if kind == .poolSwimming {
            input.swimLaps = Self.swimLaps(in: workout)
            input.poolLength = (metadata[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter())
        }
        input.totalDistance = workout.statistics(for: kind.distanceType)?.sumQuantity()?.doubleValue(for: .meter())
        input.activeEnergy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        input.elevationAscended = (metadata[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter())
        input.elevationDescended = (metadata[HKMetadataKeyElevationDescended] as? HKQuantity)?.doubleValue(for: .meter())
        input.averageHeartRate = heartRate?.averageQuantity()?.doubleValue(for: bpm)
        input.maxHeartRate = heartRate?.maximumQuantity()?.doubleValue(for: bpm)
        input.utcOffset = timeZone.secondsFromGMT(for: workout.startDate)
        return input
    }

    /// Samples recorded by the same device as the workout during it. Filtering by source keeps
    /// the iPhone's own pedometer distance from being counted on top of the Watch's.
    private func intervalSamples(of type: HKQuantityType, unit: HKUnit, during workout: HKWorkout) async throws -> [WorkoutExportInput.IntervalSample] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
            HKQuery.predicateForObjects(from: workout.sourceRevision.source),
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            WorkoutExportInput.IntervalSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
        }
    }

    /// Pause → resume pairs (manual and auto-pause). A pause never resumed lasts until the end.
    static func pauses(in workout: HKWorkout) -> [DateInterval] {
        let events = (workout.workoutEvents ?? []).sorted { $0.dateInterval.start < $1.dateInterval.start }
        var pauses: [DateInterval] = []
        var pausedAt: Date?
        for event in events {
            switch event.type {
            case .pause, .motionPaused:
                if pausedAt == nil { pausedAt = event.dateInterval.start }
            case .resume, .motionResumed:
                if let start = pausedAt, event.dateInterval.start > start {
                    pauses.append(DateInterval(start: start, end: event.dateInterval.start))
                }
                pausedAt = nil
            default:
                break
            }
        }
        if let start = pausedAt, workout.endDate > start {
            pauses.append(DateInterval(start: start, end: workout.endDate))
        }
        return pauses
    }

    /// Apple Watch records one `.lap` event per pool length, tagged with the stroke style.
    static func swimLaps(in workout: HKWorkout) -> [WorkoutExportInput.SwimLap] {
        (workout.workoutEvents ?? [])
            .filter { $0.type == .lap && $0.dateInterval.duration > 0 }
            .map { event in
                let style = (event.metadata?[HKMetadataKeySwimmingStrokeStyle] as? NSNumber)
                    .flatMap { HKSwimmingStrokeStyle(rawValue: $0.intValue) }
                return WorkoutExportInput.SwimLap(interval: event.dateInterval, stroke: style.flatMap(FITSwimStroke.init))
            }
    }
}

extension FITSwimStroke {
    init?(_ style: HKSwimmingStrokeStyle) {
        switch style {
        case .freestyle: self = .freestyle
        case .backstroke: self = .backstroke
        case .breaststroke: self = .breaststroke
        case .butterfly: self = .butterfly
        case .kickboard: self = .drill
        case .mixed: self = .mixed
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}

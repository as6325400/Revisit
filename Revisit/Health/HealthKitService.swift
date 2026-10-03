import CoreLocation
import HealthKit

/// All reads from HealthKit go through here.
final class HealthKitService {
    let store = HKHealthStore()

    var isAvailable: Bool {
        #if DEBUG
        if DemoData.skipsHealthKit { return false }
        #endif
        return HKHealthStore.isHealthDataAvailable()
    }

    static let supportedActivityTypes: [HKWorkoutActivityType] = [.running, .walking, .hiking, .cycling, .swimming]

    private static let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    private static var readTypes: Set<HKObjectType> {
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.swimmingStrokeCount),
        ]
    }

    /// Revisit never writes to Health. Debug builds ask for write access so
    /// `SampleDataSeeder` can put test workouts into the simulator.
    private static var shareTypes: Set<HKSampleType> {
        #if DEBUG
        [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
            HKQuantityType(.distanceSwimming),
            HKQuantityType(.swimmingStrokeCount),
        ]
        #else
        []
        #endif
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
    }

    // MARK: - Workouts

    struct WorkoutChanges {
        var added: [HKWorkout]
        var deletedIDs: [UUID]
        var newAnchor: HKQueryAnchor
    }

    /// Workouts added or deleted since `anchor` (everything when `anchor` is nil).
    func workoutChanges(since anchor: HKQueryAnchor?) async throws -> WorkoutChanges {
        let predicate = NSCompoundPredicate(
            orPredicateWithSubpredicates: Self.supportedActivityTypes.map { HKQuery.predicateForWorkouts(with: $0) }
        )
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout(predicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        return WorkoutChanges(
            added: result.addedSamples,
            deletedIDs: result.deletedObjects.map(\.uuid),
            newAnchor: result.newAnchor
        )
    }

    func workout(with id: UUID) async throws -> HKWorkout? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObject(with: id))],
            sortDescriptors: [],
            limit: 1
        )
        return try await descriptor.result(for: store).first
    }

    // MARK: - Route & heart rate

    func routeLocations(for workout: HKWorkout) async throws -> [RawLocation] {
        let routes = try await HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store)

        var locations: [RawLocation] = []
        for route in routes {
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                locations.append(RawLocation(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    timestamp: location.timestamp,
                    speed: location.speed,
                    horizontalAccuracy: location.horizontalAccuracy
                ))
            }
        }
        return locations
    }

    func heartRates(for workout: HKWorkout) async throws -> [HeartRateSample] {
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store).map {
            HeartRateSample(date: $0.startDate, bpm: $0.quantity.doubleValue(for: Self.heartRateUnit))
        }
    }

    // MARK: - Background delivery

    func enableBackgroundDelivery() async throws {
        try await store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate)
    }

    /// Registers a long-running observer for new/deleted workouts. HealthKit's completion
    /// handler is called once `onUpdate` finishes. Must be set up at every app launch,
    /// including background launches, for background delivery to work.
    func observeWorkouts(onUpdate: @escaping @MainActor @Sendable () async -> Void) -> HKObserverQuery {
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { _, completionHandler, error in
            let completion = UncheckedSendable(completionHandler)
            guard error == nil else {
                completion.value()
                return
            }
            Task { @MainActor in
                await onUpdate()
                completion.value()
            }
        }
        store.execute(query)
        return query
    }

    /// Health data is encrypted while the phone is locked; reads fail with this error.
    static func isDatabaseInaccessible(_ error: any Error) -> Bool {
        (error as? HKError)?.code == .errorDatabaseInaccessible
    }
}

// MARK: - HKWorkout mapping

/// The fields of an `HKWorkout` that Revisit keeps.
nonisolated struct WorkoutSummary: Sendable {
    var id: UUID
    var kind: WorkoutKind
    var startDate: Date
    var endDate: Date
    var duration: TimeInterval
    var distance: Double?
    var activeEnergy: Double?
    var elevationGain: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var sourceName: String
    var isIndoor: Bool
}

nonisolated extension WorkoutSummary {
    /// Nil for workout types Revisit doesn't import.
    init?(_ workout: HKWorkout) {
        guard let kind = WorkoutKind(workout: workout) else { return nil }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))

        self.init(
            id: workout.uuid,
            kind: kind,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            distance: workout.statistics(for: kind.distanceType)?.sumQuantity()?.doubleValue(for: .meter()),
            activeEnergy: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            elevationGain: (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?.doubleValue(for: .meter()),
            averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            maxHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
            sourceName: workout.sourceRevision.source.name,
            isIndoor: kind != .poolSwimming && (workout.metadata?[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue == true
        )
    }
}

nonisolated extension WorkoutKind {
    init?(workout: HKWorkout) {
        switch workout.workoutActivityType {
        case .running: self = .running
        case .walking: self = .walking
        case .hiking: self = .hiking
        case .cycling: self = .cycling
        case .swimming:
            let location = (workout.metadata?[HKMetadataKeySwimmingLocationType] as? NSNumber)
                .flatMap { HKWorkoutSwimmingLocationType(rawValue: $0.intValue) }
            self = location == .pool ? .poolSwimming : .openWaterSwimming
        default:
            return nil
        }
    }

    var activityType: HKWorkoutActivityType {
        switch self {
        case .running: .running
        case .walking: .walking
        case .hiking: .hiking
        case .cycling: .cycling
        case .openWaterSwimming, .poolSwimming: .swimming
        }
    }

    var distanceType: HKQuantityType {
        switch self {
        case .running, .walking, .hiking: HKQuantityType(.distanceWalkingRunning)
        case .cycling: HKQuantityType(.distanceCycling)
        case .openWaterSwimming, .poolSwimming: HKQuantityType(.distanceSwimming)
        }
    }
}

import Foundation
import SwiftData

/// Local cache of a HealthKit workout. HealthKit stays the source of truth;
/// this store is device-only (never synced to iCloud, per App Store guideline 5.1.3).
@Model
final class WorkoutRecord {
    /// The `HKWorkout.uuid`.
    @Attribute(.unique) var workoutID: UUID
    var kindRaw: String
    var startDate: Date
    var endDate: Date
    /// Active duration in seconds (pauses excluded).
    var duration: TimeInterval
    /// Meters.
    var distance: Double
    /// Kilocalories.
    var activeEnergy: Double?
    /// Meters.
    var elevationGain: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var sourceName: String
    /// Treadmill, indoor cycling etc. Pool swims use `WorkoutKind.poolSwimming` instead.
    var isIndoor: Bool = false
    var routeStatusRaw: String
    /// Simplified route for list thumbnails, encoded with `CoordinateCodec`.
    var previewData: Data?
    /// Full `ProcessedTrack`, encoded.
    @Attribute(.externalStorage) var trackData: Data?
    var importedAt: Date

    init(
        workoutID: UUID,
        kind: WorkoutKind,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        distance: Double,
        activeEnergy: Double?,
        elevationGain: Double?,
        averageHeartRate: Double?,
        maxHeartRate: Double?,
        sourceName: String,
        isIndoor: Bool = false
    ) {
        self.workoutID = workoutID
        self.kindRaw = kind.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.distance = distance
        self.activeEnergy = activeEnergy
        self.elevationGain = elevationGain
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.sourceName = sourceName
        self.isIndoor = isIndoor
        self.routeStatusRaw = RouteStatus.pending.rawValue
        self.importedAt = .now
    }

    var kind: WorkoutKind { WorkoutKind(rawValue: kindRaw) ?? .running }

    /// "跑步", or "室內跑步" for a treadmill run.
    var displayName: String {
        isIndoor ? "室內" + kind.displayName : kind.displayName
    }

    /// Indoor workouts and pool swims never have a route.
    var hasNoRouteByNature: Bool {
        isIndoor || kind == .poolSwimming
    }

    var routeStatus: RouteStatus {
        get { RouteStatus(rawValue: routeStatusRaw) ?? .pending }
        set { routeStatusRaw = newValue.rawValue }
    }

    var previewCoordinates: [Coordinate] {
        previewData.map(CoordinateCodec.decode) ?? []
    }

    func loadTrack() -> ProcessedTrack? {
        guard let trackData else { return nil }
        return try? ProcessedTrack.decode(trackData)
    }

    private static let previewPointLimit = 120

    /// Stores a processed route and fills in any summary fields HealthKit didn't provide.
    func applyRoute(_ track: ProcessedTrack, heartRates: [HeartRateSample]) throws {
        guard track.count >= 2 else {
            routeStatus = .none
            return
        }
        trackData = try track.encoded()
        previewData = try CoordinateCodec.encode(Simplifier.simplify(track.coordinates, maxPoints: Self.previewPointLimit))
        if distance <= 0 { distance = track.totalDistance }
        if elevationGain == nil { elevationGain = track.elevationGain }
        if averageHeartRate == nil, !heartRates.isEmpty {
            averageHeartRate = heartRates.map(\.bpm).reduce(0, +) / Double(heartRates.count)
            maxHeartRate = heartRates.map(\.bpm).max()
        }
        routeStatus = .ready
    }
}

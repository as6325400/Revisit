#if DEBUG
import Foundation
import SwiftData

/// Launch with `-demoData` to fill an in-memory store with the sample routes and skip
/// HealthKit entirely — for screenshots and UI work in the simulator.
/// Add `-onboardingCompleted YES` to skip onboarding and `-openFirstWorkout` to open a detail page;
/// `-selectKm`, `-scrollToCharts`, `-openReplay` and `-replayProgress` set up screenshots.
enum DemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoData")
    }

    /// `-openFirstWorkout`, or `-openWorkout 2` for the third newest.
    static var openedWorkoutIndex: Int? {
        if ProcessInfo.processInfo.arguments.contains("-openFirstWorkout") { return 0 }
        guard UserDefaults.standard.object(forKey: "openWorkout") != nil else { return nil }
        return UserDefaults.standard.integer(forKey: "openWorkout")
    }

    /// `-selectKm 1.2` preselects a point on the detail charts.
    static var selectedKm: Double? {
        let km = UserDefaults.standard.double(forKey: "selectKm")
        return km > 0 ? km : nil
    }

    /// `-scrollToCharts` scrolls the detail page down to the charts.
    static var scrollsToCharts: Bool {
        ProcessInfo.processInfo.arguments.contains("-scrollToCharts")
    }

    /// `-openExport` (with `-openReplay`) starts a 15 s video export straight away.
    static var opensExport: Bool {
        ProcessInfo.processInfo.arguments.contains("-openExport")
    }

    /// `-exportFIT` exports the opened workout as .fit straight away.
    static var exportsFIT: Bool {
        ProcessInfo.processInfo.arguments.contains("-exportFIT")
    }

    /// `-openReplay` opens the replay from the detail page.
    static var opensReplay: Bool {
        ProcessInfo.processInfo.arguments.contains("-openReplay")
    }

    /// `-replayProgress 0.4` freezes the replay at that point instead of auto-playing.
    static var replayProgress: Double? {
        guard UserDefaults.standard.object(forKey: "replayProgress") != nil else { return nil }
        return UserDefaults.standard.double(forKey: "replayProgress")
    }

    private static var samplesByID: [UUID: SampleWorkout] = [:]

    /// Inserts the sample workouts and returns their IDs, newest first.
    @discardableResult
    static func populate(_ context: ModelContext) -> [UUID] {
        var ids: [UUID] = []
        for sample in SampleRoutes.all(endingBefore: .now).sorted(by: { $0.start > $1.start }) {
            let record = WorkoutRecord(
                workoutID: UUID(),
                kind: sample.kind,
                startDate: sample.start,
                endDate: sample.end,
                duration: sample.end.timeIntervalSince(sample.start),
                distance: sample.distance,
                activeEnergy: sample.activeEnergy,
                elevationGain: sample.elevationGain,
                averageHeartRate: nil,
                maxHeartRate: nil,
                sourceName: "範例資料",
                isIndoor: sample.isIndoor
            )
            let track = RouteProcessor(kind: sample.kind)
                .process(locations: sample.locations, heartRates: sample.heartRates, workoutStart: sample.start)
            try? record.applyRoute(track, heartRates: sample.heartRates)
            context.insert(record)
            ids.append(record.workoutID)
            samplesByID[record.workoutID] = sample
        }
        try? context.save()
        return ids
    }

    /// What a FIT export would read from HealthKit for a demo workout.
    static func exportInput(for id: UUID) -> WorkoutExportInput? {
        guard let sample = samplesByID[id] else { return nil }
        var input = WorkoutExportInput(
            workoutID: id,
            kind: sample.kind,
            isIndoor: sample.isIndoor,
            start: sample.start,
            end: sample.end,
            duration: sample.end.timeIntervalSince(sample.start)
        )
        input.locations = sample.locations
        input.heartRates = sample.heartRates
        input.distanceSamples = sample.distanceSamples
        input.strokeSamples = sample.strokeSamples
        input.swimLaps = sample.swimLaps
        input.poolLength = sample.poolLength
        input.totalDistance = sample.distance
        input.activeEnergy = sample.activeEnergy
        input.elevationAscended = sample.elevationGain > 0 ? sample.elevationGain : nil
        input.utcOffset = TimeZone.current.secondsFromGMT(for: sample.start)
        return input
    }
}
#endif

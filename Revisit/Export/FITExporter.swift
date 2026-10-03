import Foundation

/// Builds a .fit file for a workout and writes it to a temporary file for sharing.
final class FITExporter {
    private let health: HealthKitService

    init(health: HealthKitService) {
        self.health = health
    }

    func export(_ record: WorkoutRecord) async throws -> URL {
        let input = try await exportInput(for: record)
        let data = FITActivityBuilder.build(input).encoded()
        let url = URL.temporaryDirectory.appending(path: Self.fileName(for: record))
        try data.write(to: url, options: .atomic)
        return url
    }

    private func exportInput(for record: WorkoutRecord) async throws -> WorkoutExportInput {
        #if DEBUG
        if DemoData.isEnabled, let input = DemoData.exportInput(for: record.workoutID) {
            return input
        }
        #endif
        // Asks only for permissions added since onboarding (e.g. swim stroke counts).
        try await health.requestAuthorization()
        guard let workout = try await health.workout(with: record.workoutID) else {
            throw FITExportError.workoutNotFound
        }
        return try await health.exportInput(for: workout, kind: record.kind, isIndoor: record.isIndoor)
    }

    /// e.g. "Revisit_20260927_0712_Run.fit"
    static func fileName(for record: WorkoutRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let sport = switch (record.kind, record.isIndoor) {
        case (.running, false): "Run"
        case (.running, true): "TreadmillRun"
        case (.walking, false): "Walk"
        case (.walking, true): "IndoorWalk"
        case (.hiking, _): "Hike"
        case (.cycling, false): "Ride"
        case (.cycling, true): "IndoorRide"
        case (.openWaterSwimming, _): "OpenWaterSwim"
        case (.poolSwimming, _): "PoolSwim"
        }
        return "Revisit_\(formatter.string(from: record.startDate))_\(sport).fit"
    }
}

enum FITExportError: LocalizedError {
    case workoutNotFound

    var errorDescription: String? {
        switch self {
        case .workoutNotFound: "在「健康」裡找不到這筆運動，可能已經被刪除。"
        }
    }
}

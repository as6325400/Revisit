import Foundation
import Observation
import SwiftData

/// Composition root. A singleton because the app delegate needs it during background
/// launches, before any SwiftUI scene exists.
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let health = HealthKitService()
    let notifications = NotificationService()
    let router = AppRouter()
    let sync: WorkoutSyncCoordinator
    let fitExporter: FITExporter

    private init() {
        #if DEBUG
        let inMemory = DemoData.isEnabled
        #else
        let inMemory = false
        #endif
        do {
            // Device-only store: health data must not go to iCloud.
            let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
            container = try ModelContainer(for: WorkoutRecord.self, configurations: configuration)
        } catch {
            fatalError("無法建立本機資料庫：\(error)")
        }
        sync = WorkoutSyncCoordinator(health: health, context: container.mainContext, notifications: notifications)
        fitExporter = FITExporter(health: health)

        #if DEBUG
        if DemoData.isEnabled {
            let ids = DemoData.populate(container.mainContext)
            if let index = DemoData.openedWorkoutIndex, ids.indices.contains(index) {
                router.openWorkout(ids[index])
            }
        }
        #endif
    }

    nonisolated static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@Observable
final class AppRouter {
    enum Tab: Hashable {
        case feed, settings
    }

    var selectedTab: Tab = .feed
    var feedPath: [UUID] = []

    func openWorkout(_ id: UUID) {
        selectedTab = .feed
        feedPath = [id]
    }
}

enum StorageKeys {
    static let onboardingCompleted = "onboardingCompleted"
}

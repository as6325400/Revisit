import Foundation
import HealthKit
import Observation
import SwiftData
import UIKit

/// Keeps the local SwiftData cache in step with HealthKit.
///
/// Flow: Watch finishes a workout → it syncs to the iPhone's Health store → HealthKit wakes
/// the app through the observer query → `sync` pulls the changes with an anchored query,
/// processes the new route and posts a local notification.
@Observable
final class WorkoutSyncCoordinator {
    enum Trigger {
        case initial, foreground, manual, background, unlock
    }

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastErrorMessage: String?
    /// Health data can't be read while the phone is locked; we retry once it's unlocked.
    private(set) var isWaitingForUnlock = false

    private let health: HealthKitService
    private let context: ModelContext
    private let notifications: NotificationService
    private let defaults: UserDefaults

    private var observerQuery: HKObserverQuery?
    private var unlockObserver: (any NSObjectProtocol)?
    private var needsAnotherPass = false
    private var isProcessingPending = false
    private var processingIDs: Set<UUID> = []

    private static let anchorKey = "sync.workoutAnchor"
    private static let importVersionKey = "sync.importVersion"
    /// Bump when the set of imported workouts changes, to re-read all of Health once.
    /// 2: indoor workouts and pool swims.
    private static let importVersion = 2
    private static let lastSyncKey = "sync.lastSyncDate"
    /// Only workouts that ended this recently get a "new workout" notification.
    private static let notificationWindow: TimeInterval = 6 * 3600

    init(health: HealthKitService, context: ModelContext, notifications: NotificationService, defaults: UserDefaults = .standard) {
        self.health = health
        self.context = context
        self.notifications = notifications
        self.defaults = defaults
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date

        // Workouts skipped by an older version are behind the saved anchor; start over.
        // Existing records are kept (inserts skip known IDs).
        if defaults.integer(forKey: Self.importVersionKey) < Self.importVersion {
            defaults.removeObject(forKey: Self.anchorKey)
            defaults.set(Self.importVersion, forKey: Self.importVersionKey)
        }
    }

    /// Call on every launch once the user has granted access. Safe to call more than once.
    func startObserving() {
        guard observerQuery == nil, health.isAvailable else { return }

        observerQuery = health.observeWorkouts { [weak self] in
            await self?.sync(trigger: .background)
        }
        Task {
            do {
                try await health.enableBackgroundDelivery()
            } catch {
                lastErrorMessage = "無法啟用背景同步：\(error.localizedDescription)"
            }
        }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isWaitingForUnlock else { return }
                await self.sync(trigger: .unlock)
            }
        }
    }

    // MARK: - Sync

    func sync(trigger: Trigger) async {
        guard health.isAvailable else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            needsAnotherPass = false
            await syncOnce(trigger: trigger)
        } while needsAnotherPass
    }

    private func syncOnce(trigger: Trigger) async {
        do {
            let anchor = loadAnchor()
            let isInitialImport = anchor == nil
            let changes = try await health.workoutChanges(since: anchor)

            try deleteRecords(ids: changes.deletedIDs)
            let fresh = try insertRecords(for: changes.added)
            try context.save()
            saveAnchor(changes.newAnchor)

            isWaitingForUnlock = false
            lastErrorMessage = nil
            lastSyncDate = .now
            defaults.set(lastSyncDate, forKey: Self.lastSyncKey)

            // On first import there may be hundreds of workouts; those are processed lazily
            // by `processPendingRoutes`. New workouts after that are processed right away so
            // the notification opens straight into a ready map.
            guard !isInitialImport else { return }
            for (record, workout) in fresh.sorted(by: { $0.0.startDate > $1.0.startDate }) {
                await processRoute(for: record, workout: workout)
                if shouldNotify(about: record) {
                    await notifications.notifyNewWorkout(record)
                }
            }
        } catch where HealthKitService.isDatabaseInaccessible(error) {
            isWaitingForUnlock = true
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func shouldNotify(about record: WorkoutRecord) -> Bool {
        (record.routeStatus == .ready || record.hasNoRouteByNature)
            && record.endDate.timeIntervalSinceNow > -Self.notificationWindow
            && UIApplication.shared.applicationState != .active
    }

    private func insertRecords(for workouts: [HKWorkout]) throws -> [(WorkoutRecord, HKWorkout)] {
        var inserted: [(WorkoutRecord, HKWorkout)] = []
        for workout in workouts {
            guard let summary = WorkoutSummary(workout), try record(with: summary.id) == nil else { continue }
            let record = WorkoutRecord(
                workoutID: summary.id,
                kind: summary.kind,
                startDate: summary.startDate,
                endDate: summary.endDate,
                duration: summary.duration,
                distance: summary.distance ?? 0,
                activeEnergy: summary.activeEnergy,
                elevationGain: summary.elevationGain,
                averageHeartRate: summary.averageHeartRate,
                maxHeartRate: summary.maxHeartRate,
                sourceName: summary.sourceName,
                isIndoor: summary.isIndoor
            )
            context.insert(record)
            inserted.append((record, workout))
        }
        return inserted
    }

    private func deleteRecords(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try context.delete(model: WorkoutRecord.self, where: #Predicate { ids.contains($0.workoutID) })
    }

    private func record(with id: UUID) throws -> WorkoutRecord? {
        var descriptor = FetchDescriptor<WorkoutRecord>(predicate: #Predicate { $0.workoutID == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Route processing

    /// Fetches and cleans the route for one record. Does nothing if it's already in progress.
    func processRoute(for record: WorkoutRecord, workout knownWorkout: HKWorkout? = nil) async {
        let id = record.workoutID
        if record.hasNoRouteByNature {
            record.routeStatus = .none
            try? context.save()
            return
        }
        guard !processingIDs.contains(id) else { return }
        processingIDs.insert(id)
        defer { processingIDs.remove(id) }

        do {
            let fetched: HKWorkout?
            if let knownWorkout {
                fetched = knownWorkout
            } else {
                fetched = try await health.workout(with: id)
            }
            guard let workout = fetched else {
                // Deleted from Health; the next sync removes the record.
                record.routeStatus = .failed
                try context.save()
                return
            }
            let locations = try await health.routeLocations(for: workout)
            let heartRates = try await health.heartRates(for: workout)
            guard !record.isDeleted else { return }

            let track = RouteProcessor(kind: record.kind)
                .process(locations: locations, heartRates: heartRates, workoutStart: workout.startDate)
            try record.applyRoute(track, heartRates: heartRates)
        } catch where HealthKitService.isDatabaseInaccessible(error) {
            isWaitingForUnlock = true
            return
        } catch {
            guard !record.isDeleted else { return }
            record.routeStatus = .failed
        }
        try? context.save()
    }

    /// Processes every record still waiting for its route, newest first.
    func processPendingRoutes() async {
        guard !isProcessingPending else { return }
        isProcessingPending = true
        defer { isProcessingPending = false }

        let pending = RouteStatus.pending.rawValue
        let descriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.routeStatusRaw == pending },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else { return }
        for record in records {
            if isWaitingForUnlock || Task.isCancelled { break }
            await processRoute(for: record)
        }
    }

    /// Drops the local cache and imports everything from Health again.
    func reimportAll() async {
        do {
            try context.delete(model: WorkoutRecord.self)
            try context.save()
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        defaults.removeObject(forKey: Self.anchorKey)
        await sync(trigger: .manual)
        await processPendingRoutes()
    }

    // MARK: - Anchor

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: Self.anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: Self.anchorKey)
    }
}

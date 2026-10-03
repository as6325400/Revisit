import UserNotifications

final class NotificationService {
    nonisolated static let workoutIDKey = "workoutID"

    private var center: UNUserNotificationCenter { .current() }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func notifyNewWorkout(_ record: WorkoutRecord) async {
        let content = UNMutableNotificationContent()
        content.title = "\(record.displayName) \(Formatters.distance(record.distance))"
        content.body = record.hasNoRouteByNature
            ? "時間 \(Formatters.duration(record.duration))・點開查看或匯出 .fit"
            : "時間 \(Formatters.duration(record.duration))・點開看這次的路線"
        content.sound = .default
        content.userInfo = [Self.workoutIDKey: record.workoutID.uuidString]

        let request = UNNotificationRequest(identifier: record.workoutID.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}

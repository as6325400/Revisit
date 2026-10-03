import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        guard !AppModel.isRunningTests else { return true }
        UNUserNotificationCenter.current().delegate = self

        // HealthKit background delivery only works if the observer query is registered
        // on every launch, including when iOS launches us in the background.
        if UserDefaults.standard.bool(forKey: StorageKeys.onboardingCompleted) {
            AppModel.shared.sync.startObserving()
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[NotificationService.workoutIDKey] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            AppModel.shared.router.openWorkout(id)
        }
    }
}

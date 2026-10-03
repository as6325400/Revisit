import SwiftUI

struct RootView: View {
    @AppStorage(StorageKeys.onboardingCompleted) private var onboardingCompleted = false
    @Environment(AppRouter.self) private var router
    @Environment(WorkoutSyncCoordinator.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if onboardingCompleted {
                mainTabs
            } else {
                OnboardingView {
                    onboardingCompleted = true
                    Task { await syncAll(.initial) }
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, onboardingCompleted else { return }
            Task { await syncAll(.foreground) }
        }
    }

    private var mainTabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            Tab("動態", systemImage: "figure.run", value: AppRouter.Tab.feed) {
                FeedView()
            }
            Tab("設定", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                SettingsView()
            }
        }
    }

    private func syncAll(_ trigger: WorkoutSyncCoordinator.Trigger) async {
        await sync.sync(trigger: trigger)
        await sync.processPendingRoutes()
    }
}

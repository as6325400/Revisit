import SwiftData
import SwiftUI

@main
struct RevisitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            if AppModel.isRunningTests {
                Text("Running tests")
            } else {
                RootView()
                    .environment(AppModel.shared.router)
                    .environment(AppModel.shared.sync)
                    .modelContainer(AppModel.shared.container)
            }
        }
    }
}

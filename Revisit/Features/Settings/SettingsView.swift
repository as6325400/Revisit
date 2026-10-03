import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(WorkoutSyncCoordinator.self) private var sync
    @Query private var records: [WorkoutRecord]
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var isConfirmingReimport = false
    #if DEBUG
    @State private var isSeeding = false
    @State private var seedMessage: String?
    #endif

    private var pendingCount: Int {
        records.count(where: { $0.routeStatus == .pending })
    }

    var body: some View {
        NavigationStack {
            Form {
                dataSection
                permissionSection
                #if DEBUG
                debugSection
                #endif
                aboutSection
            }
            .navigationTitle("設定")
            .task {
                notificationStatus = await AppModel.shared.notifications.authorizationStatus()
            }
        }
    }

    private var dataSection: some View {
        Section {
            LabeledContent("運動紀錄", value: "\(records.count) 筆")
            if pendingCount > 0 {
                LabeledContent("待整理路線", value: "\(pendingCount) 筆")
            }
            if let date = sync.lastSyncDate {
                LabeledContent("上次同步", value: date.formatted(.relative(presentation: .named)))
            }
            if sync.isWaitingForUnlock {
                Label("iPhone 鎖定中，解鎖後會自動同步", systemImage: "lock")
                    .foregroundStyle(.orange)
            }
            if let error = sync.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                Task {
                    await sync.sync(trigger: .manual)
                    await sync.processPendingRoutes()
                }
            } label: {
                HStack {
                    Text("立即同步")
                    if sync.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(sync.isSyncing)

            Button("重新匯入全部紀錄", role: .destructive) {
                isConfirmingReimport = true
            }
            .disabled(sync.isSyncing)
            .confirmationDialog("清除本機快取並從「健康」重新匯入？", isPresented: $isConfirmingReimport, titleVisibility: .visible) {
                Button("重新匯入", role: .destructive) {
                    Task { await sync.reimportAll() }
                }
            } message: {
                Text("「健康」裡的資料不會受影響。")
            }
        } header: {
            Text("資料")
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("通知", value: notificationStatusText)
            Button("開啟 Revisit 的系統設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("權限")
        } footer: {
            Text("「健康」資料的讀取權限在「健康」App → 右上角頭像 → App → Revisit 調整。")
        }
    }

    private var notificationStatusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: "已開啟"
        case .denied: "已關閉"
        case .notDetermined: "尚未設定"
        case nil: "—"
        @unknown default: "—"
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Button {
                Task { await seed() }
            } label: {
                HStack {
                    Text("寫入範例運動到「健康」")
                    if isSeeding {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSeeding)
            if let seedMessage {
                Text(seedMessage).font(.footnote)
            }
        } header: {
            Text("開發測試")
        } footer: {
            Text("在模擬器上產生幾筆台灣的範例路線（跑步、健行、騎車、游泳）。只有 Debug 版會出現。")
        }
    }

    private func seed() async {
        isSeeding = true
        defer { isSeeding = false }
        do {
            let count = try await SampleDataSeeder.seed(using: AppModel.shared.health)
            seedMessage = "已寫入 \(count) 筆範例運動。"
            await sync.sync(trigger: .manual)
            await sync.processPendingRoutes()
        } catch {
            seedMessage = "寫入失敗：\(error.localizedDescription)"
        }
    }
    #endif

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: Bundle.main.appVersion)
        } header: {
            Text("關於")
        } footer: {
            Text("所有資料只存在這台 iPhone，不會上傳到任何伺服器。")
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

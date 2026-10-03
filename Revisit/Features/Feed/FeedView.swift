import SwiftData
import SwiftUI

struct FeedView: View {
    @Query(sort: \WorkoutRecord.startDate, order: .reverse) private var records: [WorkoutRecord]
    @Environment(AppRouter.self) private var router
    @Environment(WorkoutSyncCoordinator.self) private var sync
    @State private var filter: WorkoutKind?

    private var visibleRecords: [WorkoutRecord] {
        guard let filter else { return records }
        return records.filter { $0.kind == filter }
    }

    private var availableKinds: [WorkoutKind] {
        WorkoutKind.allCases.filter { kind in records.contains { $0.kind == kind } }
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.feedPath) {
            List {
                if availableKinds.count > 1 {
                    KindFilterBar(kinds: availableKinds, selection: $filter)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
                ForEach(visibleRecords) { record in
                    NavigationLink(value: record.workoutID) {
                        WorkoutRow(record: record)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("動態")
            .navigationDestination(for: UUID.self) { id in
                WorkoutDetailView(workoutID: id)
            }
            .refreshable {
                await sync.sync(trigger: .manual)
                await sync.processPendingRoutes()
            }
            .overlay {
                if records.isEmpty {
                    emptyState
                }
            }
            .toolbar {
                if sync.isSyncing {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if sync.isSyncing {
            ProgressView("正在讀取「健康」資料…")
        } else {
            ContentUnavailableView {
                Label("還沒有運動紀錄", systemImage: "figure.run")
            } description: {
                Text("用 Apple Watch 的「體能訓練」記錄一次戶外跑步、走路、健行、騎車或開放水域游泳，同步後就會出現在這裡。\n\n如果明明有紀錄卻沒出現，請到「健康」App → 頭像 → App → Revisit，確認讀取權限都有打開。")
            }
        }
    }
}

private struct KindFilterBar: View {
    let kinds: [WorkoutKind]
    @Binding var selection: WorkoutKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", symbol: nil, isSelected: selection == nil) { selection = nil }
                ForEach(kinds) { kind in
                    chip(title: kind.displayName, symbol: kind.symbolName, isSelected: selection == kind) {
                        selection = kind
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, symbol: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

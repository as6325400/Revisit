import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var isRequesting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "map.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Revisit")
                    .font(.largeTitle.bold())
                Text("把 Apple Watch 記錄的每一次運動，\n在地圖上重新走一遍。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    symbol: "heart.text.square",
                    title: "讀取「健康」資料",
                    detail: "體能訓練、GPS 路線與心率。只讀取，不會修改。"
                )
                FeatureRow(
                    symbol: "bell.badge",
                    title: "運動結束就通知你",
                    detail: "Watch 同步到 iPhone 後，自動整理好路線。"
                )
                FeatureRow(
                    symbol: "lock.shield",
                    title: "資料只在這台 iPhone",
                    detail: "不上傳、不經過任何伺服器。"
                )
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(spacing: 12) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await connect() }
                } label: {
                    Text("連接「健康」")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                Text("提醒：不要從多工畫面把 Revisit 滑掉，iOS 才能在背景喚醒它同步新的運動。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func connect() async {
        let model = AppModel.shared
        guard model.health.isAvailable else {
            errorMessage = "這台裝置不支援「健康」資料。"
            return
        }
        isRequesting = true
        defer { isRequesting = false }

        do {
            try await model.health.requestAuthorization()
            await model.notifications.requestAuthorization()
            model.sync.startObserving()
            onFinish()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    OnboardingView {}
}

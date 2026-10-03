import AVKit
import Photos
import SwiftUI

/// Renders the replay to an MP4, then offers saving to Photos or sharing.
struct ExportView: View {
    @State private var model: ExportModel
    @Environment(\.dismiss) private var dismiss

    init(controller: ReplayController, kind: WorkoutKind) {
        _model = State(initialValue: ExportModel(controller: controller, kind: kind))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                GeometryReader { proxy in
                    let scale = min(1, proxy.size.width / 360, proxy.size.height / 640)
                    Group {
                        if case let .finished(url) = model.phase {
                            VideoPlayer(player: model.player(for: url))
                        } else {
                            ExportMapView(model: model)
                        }
                    }
                    .frame(width: 360, height: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                status
                    .frame(minHeight: 110)
            }
            .padding()
            .navigationTitle("匯出影片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isFinished ? "完成" : "取消") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .task { model.start() }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case let .preparing(progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                Text("正在下載沿途地圖…").font(.footnote).foregroundStyle(.secondary)
            }
        case let .rendering(progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                Text("正在產生影片 \(Int(progress * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Text("每一格都會等地圖完全載入，請保持在這個畫面。").font(.caption).foregroundStyle(.tertiary)
            }
        case let .finished(url):
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.saveToPhotos(url) }
                    } label: {
                        Label(model.isSavedToPhotos ? "已存到相簿" : "存到相簿", systemImage: model.isSavedToPhotos ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isSavedToPhotos)

                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                if let message = model.saveMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            VStack(spacing: 8) {
                Label("匯出失敗", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("重試") { model.start() }
            }
        }
    }
}

/// The map being recorded. It must be on screen: snapshots read the rendered view.
private struct ExportMapView: UIViewRepresentable {
    let model: ExportModel

    func makeUIView(context: Context) -> UIView {
        let renderer = MapboxReplayRenderer(content: model.controller.content)
        model.renderer = renderer
        return renderer.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@Observable
final class ExportModel {
    enum Phase: Equatable {
        case preparing(Double)
        case rendering(Double)
        case finished(URL)
        case failed(String)
    }

    let controller: ReplayController
    let kind: WorkoutKind

    private(set) var phase: Phase = .preparing(0)
    private(set) var isSavedToPhotos = false
    private(set) var saveMessage: String?

    @ObservationIgnored var renderer: MapboxReplayRenderer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cachedPlayer: (url: URL, player: AVPlayer)?

    init(controller: ReplayController, kind: WorkoutKind) {
        self.controller = controller
        self.kind = kind
    }

    var isFinished: Bool {
        if case .finished = phase { true } else { false }
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case let .finished(url) = phase {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func player(for url: URL) -> AVPlayer {
        if let cachedPlayer, cachedPlayer.url == url { return cachedPlayer.player }
        let player = AVPlayer(url: url)
        cachedPlayer = (url, player)
        return player
    }

    private func run() async {
        phase = .preparing(0)
        isSavedToPhotos = false
        saveMessage = nil

        // The map view is created on first layout; wait for it.
        for _ in 0..<40 where renderer == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let renderer else {
            phase = .failed("地圖沒有準備好。")
            return
        }

        await renderer.preload([]) { [weak self] fraction in
            if case .preparing = self?.phase { self?.phase = .preparing(fraction) }
        }
        guard !Task.isCancelled else { return }

        #if DEBUG
        let began = ContinuousClock.now
        #endif
        phase = .rendering(0)
        do {
            let exporter = ReplayVideoExporter(controller: controller, renderer: renderer, kind: kind)
            let url = try await exporter.export(duration: controller.duration) { fraction in
                phase = .rendering(fraction)
            }
            #if DEBUG
            print("REPLAYSTATS export finished in \(ContinuousClock.now - began) -> \(url.path)")
            #endif
            phase = .finished(url)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "沒有相簿權限，可以到「設定」→ Revisit →「照片」開啟。"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            isSavedToPhotos = true
            saveMessage = nil
        } catch {
            saveMessage = "存到相簿失敗：\(error.localizedDescription)"
        }
    }
}

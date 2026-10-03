import SwiftUI

/// Full-screen 3D flyover of a workout.
struct ReplayView: View {
    let kind: WorkoutKind

    @State private var controller: ReplayController
    @State private var isExporting = false
    @Environment(\.dismiss) private var dismiss

    init(visualization: RouteVisualization, metric: RouteMetric, kind: WorkoutKind) {
        self.kind = kind
        _controller = State(initialValue: ReplayController(visualization: visualization, metric: metric))
    }

    var body: some View {
        ZStack {
            ReplayMapView(controller: controller)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    ReplayStats(controller: controller, kind: kind)
                    Spacer()
                    if MapboxReplayRenderer.isConfigured {
                        Button {
                            controller.stop()
                            isExporting = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("匯出影片")
                    }
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("關閉")
                }
                Spacer()
                if let loading = controller.loadingProgress {
                    PreloadCard(progress: loading) {
                        controller.skipPreload()
                    }
                }
                Spacer()
                ReplayControls(controller: controller)
            }
            .padding()
            .foregroundStyle(.white)
        }
        .statusBarHidden()
        .fullScreenCover(isPresented: $isExporting) {
            ExportView(controller: controller, kind: kind)
        }
        .onAppear {
            #if DEBUG
            if DemoData.opensExport {
                controller.duration = 15
                isExporting = true
                return
            }
            if let progress = DemoData.replayProgress {
                controller.seek(to: progress)
                return
            }
            #endif
            controller.start()
        }
        .onDisappear { controller.stop() }
    }
}

private struct ReplayMapView: UIViewRepresentable {
    let controller: ReplayController

    final class Coordinator {
        /// Keeps the renderer alive; the controller only holds it weakly.
        var renderer: (any ReplayRendering)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        // Mapbox streams tiles ahead of time and draws the route on the GPU; MapKit is the
        // fallback when no Mapbox token is configured.
        let renderer: any ReplayRendering = MapboxReplayRenderer.isConfigured
            ? MapboxReplayRenderer(content: controller.content)
            : MapKitReplayRenderer(content: controller.content)
        context.coordinator.renderer = renderer
        controller.renderer = renderer
        return renderer.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Shown while the map along the route is loading.
private struct PreloadCard: View {
    let progress: Double
    let skip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("正在載入沿途地圖…")
                .font(.headline)
            ProgressView(value: progress)
                .tint(.white)
                .frame(width: 180)
            Button("直接播放", action: skip)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(20)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }
}

// Overlays use a plain translucent fill rather than a blur material: a blur has to be
// recomputed every frame because the map underneath never stops moving.

private struct ReplayStats: View {
    let controller: ReplayController
    let kind: WorkoutKind

    var body: some View {
        let position = controller.position
        let track = controller.visualization.track
        let heartRate = track.heartRates[position.index]

        VStack(alignment: .leading, spacing: 4) {
            Label(kind.displayName, systemImage: kind.symbolName)
                .font(.subheadline.weight(.semibold))
            Text(Formatters.distance(position.distance))
                .font(.system(.title, design: .rounded).weight(.bold))
            HStack(spacing: 10) {
                Text(Formatters.duration(position.movingTime))
                Text(Formatters.pace(speed: track.speeds[position.index], style: kind.paceStyle))
                if heartRate >= 0 {
                    Label(Formatters.heartRate(heartRate), systemImage: "heart.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.footnote)
        }
        .monospacedDigit()
        .padding(12)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ReplayControls: View {
    let controller: ReplayController

    var body: some View {
        HStack(spacing: 14) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.isPlaying ? "暫停" : "播放")

            Slider(value: Binding(
                get: { controller.progress },
                set: { newValue in
                    controller.pause()
                    controller.seek(to: newValue)
                }
            ))
            .tint(Theme.route)

            Menu {
                Picker("重播長度", selection: Binding(
                    get: { controller.duration },
                    set: { controller.duration = $0 }
                )) {
                    ForEach(ReplayController.durationChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) 秒").tag(seconds)
                    }
                }
            } label: {
                Text("\(Int(controller.duration))s")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 36, minHeight: 44)
            }
        }
        .padding(.horizontal, 12)
        .background(.black.opacity(0.5), in: Capsule())
        .disabled(controller.loadingProgress != nil)
    }
}

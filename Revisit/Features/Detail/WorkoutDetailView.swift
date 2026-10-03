import SwiftData
import SwiftUI

struct WorkoutDetailView: View {
    let workoutID: UUID

    @Query private var matches: [WorkoutRecord]
    @Environment(WorkoutSyncCoordinator.self) private var sync
    @State private var visualization: RouteVisualization?
    /// Cached: recomputed only when the metric changes, not on every chart scrub.
    @State private var mapContent: RouteMapContent?
    @State private var metric: RouteMetric = .pace
    @State private var selectedKm: Double?
    @State private var isThreeD = false
    @State private var isReplaying = false

    private static let chartsID = "charts"

    init(workoutID: UUID) {
        self.workoutID = workoutID
        _matches = Query(filter: #Predicate<WorkoutRecord> { $0.workoutID == workoutID })
    }

    var body: some View {
        Group {
            if let record = matches.first {
                content(for: record)
            } else {
                // Opened from a notification before the record reached the local cache.
                ProgressView("正在同步…")
                    .task { await sync.sync(trigger: .manual) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(for record: WorkoutRecord) -> some View {
        VStack(spacing: 0) {
            // The map stays put while the charts below scroll, so scrubbing stays visible.
            mapSection(for: record)
                .frame(height: 380)

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let visualization {
                        MetricPicker(
                            metrics: visualization.metrics,
                            style: record.kind.paceStyle,
                            selection: $metric,
                            scale: visualization.colorScale(for: metric)
                        )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.startDate.formatted(date: .complete, time: .shortened))
                            .foregroundStyle(.secondary)
                        Text(record.sourceName)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }

                    StatsGrid(record: record)

                    if let visualization {
                        RouteChartsView(
                            visualization: visualization,
                            style: record.kind.paceStyle,
                            selectedKm: $selectedKm
                        )
                        .id(Self.chartsID)
                    }
                }
                .padding()
            }
            #if DEBUG
            .task(id: visualization == nil) {
                guard visualization != nil else { return }
                if let km = DemoData.selectedKm { selectedKm = km }
                if DemoData.opensReplay { isReplaying = true }
                if DemoData.scrollsToCharts {
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(Self.chartsID, anchor: .top)
                }
            }
            #endif
            }
        }
        .navigationTitle(record.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ExportMenu(record: record)
            }
        }
        .onChange(of: metric) { _, newMetric in
            mapContent = visualization?.mapContent(coloredBy: newMetric)
        }
        .task(id: record.routeStatusRaw) {
            switch record.routeStatus {
            case .pending:
                await sync.processRoute(for: record)
            case .ready:
                if visualization == nil, let track = record.loadTrack() {
                    let loaded = RouteVisualization(track: track)
                    visualization = loaded
                    mapContent = loaded.mapContent(coloredBy: metric)
                }
            case .none, .failed:
                break
            }
        }
    }

    @ViewBuilder
    private func mapSection(for record: WorkoutRecord) -> some View {
        switch record.routeStatus {
        case .ready:
            if let visualization, let mapContent {
                let selected = selectedKm.flatMap(visualization.sample(nearestKm:))
                RouteMapView(
                    content: mapContent,
                    selection: selected.map { visualization.track.coordinate(at: $0.index) },
                    isThreeD: isThreeD
                )
                .ignoresSafeArea(edges: .horizontal)
                .overlay(alignment: .topLeading) {
                    if let selected {
                        SelectionReadout(sample: selected, style: record.kind.paceStyle)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button("重播", systemImage: "play.fill") {
                            isReplaying = true
                        }
                        Button(isThreeD ? "2D" : "3D") {
                            isThreeD.toggle()
                        }
                    }
                    .font(.subheadline.bold())
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                    .padding(.bottom, 16)
                }
                .fullScreenCover(isPresented: $isReplaying) {
                    ReplayView(visualization: visualization, metric: metric, kind: record.kind)
                }
            } else {
                placeholder { ProgressView() }
            }
        case .pending:
            placeholder { ProgressView("整理路線中…") }
        case .none:
            placeholder {
                if record.hasNoRouteByNature {
                    ContentUnavailableView(
                        record.displayName,
                        systemImage: record.kind.symbolName,
                        description: Text("室內運動和泳池游泳沒有 GPS 路線。\n可以從右上角匯出 .fit 檔。")
                    )
                } else {
                    ContentUnavailableView("這次運動沒有 GPS 路線", systemImage: "location.slash")
                }
            }
        case .failed:
            placeholder {
                ContentUnavailableView {
                    Label("讀取路線失敗", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("重試") { record.routeStatus = .pending }
                }
            }
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            content()
        }
    }
}

/// Segmented control choosing what colors the route, with a legend for the color ramp.
private struct MetricPicker: View {
    let metrics: [RouteMetric]
    let style: PaceStyle
    @Binding var selection: RouteMetric
    let scale: ColorScale?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if metrics.count > 1 {
                Picker("路線顏色", selection: $selection) {
                    ForEach(metrics) { metric in
                        Text(metric.title(for: style)).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
            }
            if let scale {
                HStack(spacing: 8) {
                    Text(label(scale.lower))
                    LinearGradient(colors: ColorScale.ramp.map(Color.init), startPoint: .leading, endPoint: .trailing)
                        .frame(height: 6)
                        .clipShape(Capsule())
                    Text(label(scale.upper))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Scale bounds are in the metric's raw unit (speed in m/s for pace).
    private func label(_ value: Double) -> String {
        switch selection {
        case .pace: Formatters.pace(speed: value, style: style)
        case .heartRate: Formatters.heartRate(value)
        case .elevation: Formatters.elevation(value)
        }
    }
}

private struct SelectionReadout: View {
    let sample: ChartSample
    let style: PaceStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Formatters.distance(sample.distanceKm * 1000)).fontWeight(.semibold)
            Text(Formatters.pace(speed: sample.speed, style: style))
            if let heartRate = sample.heartRate {
                Text(Formatters.heartRate(heartRate))
            }
            Text(Formatters.elevation(sample.elevation))
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct StatsGrid: View {
    let record: WorkoutRecord

    private var items: [(title: String, value: String)] {
        var items: [(String, String)] = [
            ("距離", Formatters.distance(record.distance)),
            ("時間", Formatters.duration(record.duration)),
            (record.kind.paceStyle == .kilometersPerHour ? "平均速度" : "平均配速",
             Formatters.pace(distance: record.distance, duration: record.duration, style: record.kind.paceStyle)),
        ]
        if let gain = record.elevationGain, !record.hasNoRouteByNature { items.append(("爬升", Formatters.elevation(gain))) }
        if let average = record.averageHeartRate { items.append(("平均心率", Formatters.heartRate(average))) }
        if let max = record.maxHeartRate { items.append(("最高心率", Formatters.heartRate(max))) }
        if let energy = record.activeEnergy { items.append(("動態消耗", Formatters.energy(energy))) }
        return items
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            ForEach(items, id: \.title) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
        }
    }
}

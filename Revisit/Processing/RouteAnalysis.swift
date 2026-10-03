import Foundation

/// What the route line is colored by, and which charts are shown.
nonisolated enum RouteMetric: String, CaseIterable, Identifiable, Sendable {
    case pace
    case heartRate
    case elevation

    var id: String { rawValue }

    func title(for style: PaceStyle) -> String {
        switch self {
        case .pace: style == .kilometersPerHour ? "速度" : "配速"
        case .heartRate: "心率"
        case .elevation: "高度"
        }
    }

    /// Per-point values for coloring; higher means a hotter color. Nil is unknown.
    /// Pace and heart rate are smoothed further than the stored track so the line
    /// shows trends instead of second-to-second noise.
    func intensities(in track: ProcessedTrack) -> [Double?] {
        switch self {
        case .pace:
            RouteSampling.smoothed(track.speeds.map { $0 }, window: 21, segments: track.segments)
        case .heartRate:
            RouteSampling.smoothed(track.heartRates.map { $0 >= 0 ? $0 : nil }, window: 11, segments: track.segments)
        case .elevation:
            track.altitudes.map { $0 }
        }
    }

    /// The value plotted on this metric's chart.
    func chartValue(_ sample: ChartSample, style: PaceStyle) -> Double? {
        switch self {
        case .pace: sample.speed >= style.minimumChartSpeed ? style.paceValue(speed: sample.speed) : nil
        case .heartRate: sample.heartRate
        case .elevation: sample.elevation
        }
    }

    /// Metrics worth showing for this track: heart rate needs samples, elevation needs some relief.
    static func available(in track: ProcessedTrack) -> [RouteMetric] {
        var metrics: [RouteMetric] = [.pace]
        if track.hasHeartRate { metrics.append(.heartRate) }
        if let low = track.altitudes.min(), let high = track.altitudes.max(), high - low >= 3 {
            metrics.append(.elevation)
        }
        return metrics
    }
}

nonisolated extension PaceStyle {
    /// Seconds per km, km/h, or seconds per 100 m. Nil when not moving.
    func paceValue(speed: Double) -> Double? {
        switch self {
        case .minutesPerKilometer: speed > 0 ? 1000 / speed : nil
        case .kilometersPerHour: max(0, speed) * 3.6
        case .minutesPer100Meters: speed > 0 ? 100 / speed : nil
        }
    }

    /// Below this speed (m/s) a point counts as standing still, so it's left off pace charts
    /// (pace shoots toward infinity as speed approaches zero).
    var minimumChartSpeed: Double {
        switch self {
        case .minutesPerKilometer: 0.5
        case .kilometersPerHour: 0
        case .minutesPer100Meters: 0.2
        }
    }
}

/// One point on the distance-based charts.
nonisolated struct ChartSample: Identifiable, Equatable, Sendable {
    /// Index into the `ProcessedTrack`.
    var index: Int
    var distanceKm: Double
    var elevation: Double
    /// m/s
    var speed: Double
    var heartRate: Double?

    var id: Int { index }
}

nonisolated enum RouteSampling {
    /// Track indices within `segment` spaced at least `spacing` meters apart,
    /// always including the segment's first and last point.
    static func indices(in track: ProcessedTrack, segment: Range<Int>, spacing: Double) -> [Int] {
        guard let first = segment.first, let last = segment.last else { return [] }
        var result = [first]
        var lastDistance = track.distances[first]
        for index in segment.dropFirst() where track.distances[index] - lastDistance >= spacing {
            result.append(index)
            lastDistance = track.distances[index]
        }
        if result.last != last { result.append(last) }
        return result
    }

    /// Centered moving average over the known values in each window, never crossing segments.
    static func smoothed(_ values: [Double?], window: Int, segments: [Range<Int>]) -> [Double?] {
        var result = values
        let half = window / 2
        for segment in segments {
            for index in segment where values[index] != nil {
                let lower = max(segment.lowerBound, index - half)
                let upper = min(segment.upperBound - 1, index + half)
                var sum = 0.0
                var count = 0
                for j in lower...upper {
                    if let value = values[j] {
                        sum += value
                        count += 1
                    }
                }
                result[index] = sum / Double(count)
            }
        }
        return result
    }

    static func chartSamples(for track: ProcessedTrack, maxPoints: Int = 300) -> [ChartSample] {
        let spacing = max(1, track.totalDistance / Double(maxPoints))
        return track.segments
            .flatMap { indices(in: track, segment: $0, spacing: spacing) }
            .map { index in
                ChartSample(
                    index: index,
                    distanceKm: track.distances[index] / 1000,
                    elevation: track.altitudes[index],
                    speed: track.speeds[index],
                    heartRate: track.heartRates[index] >= 0 ? track.heartRates[index] : nil
                )
            }
    }
}

/// What a map renderer needs to draw a colored route. Engine-agnostic, so a Mapbox
/// renderer could take the same input.
nonisolated struct RouteMapContent: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var coordinates: [Coordinate]
        /// One color per coordinate.
        var colors: [RGB]
    }

    var segments: [Segment]
    var start: Coordinate?
    var end: Coordinate?
    /// Start and finish are close enough to show one marker.
    var isLoop: Bool
}

/// Precomputed display data for one track: evenly spaced map points and chart samples.
nonisolated struct RouteVisualization: Sendable {
    let track: ProcessedTrack
    let metrics: [RouteMetric]
    let chartSamples: [ChartSample]
    /// Per segment, track indices spaced evenly by distance. Even spacing matters because
    /// `MKGradientPolylineRenderer` places colors by point position.
    private let displayIndices: [[Int]]

    static let maxMapPoints = 2000

    init(track: ProcessedTrack) {
        self.track = track
        metrics = RouteMetric.available(in: track)
        chartSamples = RouteSampling.chartSamples(for: track)
        let spacing = max(2, track.totalDistance / Double(Self.maxMapPoints))
        displayIndices = track.segments.map { RouteSampling.indices(in: track, segment: $0, spacing: spacing) }
    }

    func colorScale(for metric: RouteMetric) -> ColorScale? {
        ColorScale(values: metric.intensities(in: track))
    }

    func mapContent(coloredBy metric: RouteMetric) -> RouteMapContent {
        let intensities = metric.intensities(in: track)
        let scale = ColorScale(values: intensities)
        let segments = displayIndices.map { indices in
            RouteMapContent.Segment(
                coordinates: indices.map(track.coordinate(at:)),
                colors: indices.map { scale?.color(for: intensities[$0]) ?? ColorScale.unknown }
            )
        }
        let start = track.isEmpty ? nil : track.coordinate(at: 0)
        let end = track.isEmpty ? nil : track.coordinate(at: track.count - 1)
        let isLoop = start.flatMap { s in end.map { Geo.distance(s, $0) < 50 } } ?? false
        return RouteMapContent(segments: segments, start: start, end: end, isLoop: isLoop)
    }

    /// The chart sample nearest to a distance along the route.
    func sample(nearestKm km: Double) -> ChartSample? {
        chartSamples.min { abs($0.distanceKm - km) < abs($1.distanceKm - km) }
    }
}

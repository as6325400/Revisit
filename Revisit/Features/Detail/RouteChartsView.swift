import Charts
import SwiftUI

/// Distance-based charts. Dragging across any chart selects a point, shared with the map.
struct RouteChartsView: View {
    let visualization: RouteVisualization
    let style: PaceStyle
    @Binding var selectedKm: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(visualization.metrics) { metric in
                MetricChart(
                    metric: metric,
                    points: points(for: metric),
                    style: style,
                    selectedKm: $selectedKm
                )
            }
        }
    }

    private func points(for metric: RouteMetric) -> [ChartPoint] {
        visualization.chartSamples.compactMap { sample in
            metric.chartValue(sample, style: style).map {
                ChartPoint(id: sample.index, km: sample.distanceKm, value: $0)
            }
        }
    }
}

private struct ChartPoint: Identifiable {
    let id: Int
    let km: Double
    let value: Double
}

private struct MetricChart: View {
    let metric: RouteMetric
    let points: [ChartPoint]
    let style: PaceStyle
    @Binding var selectedKm: Double?

    /// Lower pace numbers are faster, so pace charts put small values on top.
    private var isReversed: Bool {
        metric == .pace && style != .kilometersPerHour
    }

    /// Bottom of the filled area: a little below the lowest value, but never below zero
    /// for values that can't be negative (speed, heart rate).
    private var baseline: Double {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return 0 }
        let padded = low - max((high - low) * 0.1, 1)
        return low >= 0 ? max(0, padded) : padded
    }

    private var tint: Color {
        switch metric {
        case .pace: .blue
        case .heartRate: .red
        case .elevation: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title(for: style))
                .font(.headline)
            chart
                .frame(height: 120)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                if isReversed {
                    LineMark(x: .value("距離", point.km), y: .value(metric.title(for: style), point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                } else {
                    AreaMark(
                        x: .value("距離", point.km),
                        yStart: .value("基準", baseline),
                        yEnd: .value(metric.title(for: style), point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint.opacity(0.35))
                    LineMark(x: .value("距離", point.km), y: .value(metric.title(for: style), point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                }
            }
            if let selectedKm {
                RuleMark(x: .value("選取", selectedKm))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXSelection(value: $selectedKm)
        .chartYScale(domain: .automatic(includesZero: false, reversed: isReversed))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let km = value.as(Double.self) {
                        Text("\(km.formatted(.number.precision(.fractionLength(0...1)))) km")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                    }
                }
            }
        }
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .pace: Formatters.paceValue(value, style: style)
        case .heartRate: "\(Int(value.rounded()))"
        case .elevation: "\(Int(value.rounded())) m"
        }
    }
}

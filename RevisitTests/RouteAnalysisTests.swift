import Foundation
import Testing
@testable import Revisit

struct ColorScaleTests {
    @Test func rampEndsAreFirstAndLastColors() {
        #expect(ColorScale.color(at: 0) == ColorScale.ramp.first)
        #expect(ColorScale.color(at: 1) == ColorScale.ramp.last)
        #expect(ColorScale.color(at: -3) == ColorScale.ramp.first)
        #expect(ColorScale.color(at: 7) == ColorScale.ramp.last)
    }

    @Test func percentilesIgnoreOutliers() throws {
        var values: [Double?] = (1...100).map { Double($0) }
        values.append(10_000)
        let scale = try #require(ColorScale(values: values))
        #expect(scale.upper < 100)
        #expect(scale.lower > 1)
        #expect(scale.fraction(of: 10_000) == 1)
        #expect(scale.fraction(of: -5) == 0)
    }

    @Test func unknownValuesAreGray() throws {
        let scale = try #require(ColorScale(values: [1, nil, 3]))
        #expect(scale.color(for: nil) == ColorScale.unknown)
        #expect(scale.color(for: 2) != ColorScale.unknown)
    }

    @Test func noKnownValuesMeansNoScale() {
        #expect(ColorScale(values: [nil, nil]) == nil)
        #expect(ColorScale(values: []) == nil)
    }

    @Test func constantValuesSitInTheMiddle() throws {
        let scale = try #require(ColorScale(values: [5, 5, 5]))
        #expect(scale.fraction(of: 5) == 0.5)
    }
}

struct RouteAnalysisTests {
    private func track(seconds: Int = 600, heartRate: Bool = true, climb: Double = 0) -> ProcessedTrack {
        let locations = TestRoutes.straightLine(seconds: seconds, speed: 3) { second in
            10 + climb * Double(second) / Double(seconds)
        }
        let rates = heartRate
            ? stride(from: 0, through: seconds, by: 5).map { HeartRateSample(date: TestRoutes.start + TimeInterval($0), bpm: 140) }
            : []
        return RouteProcessor(kind: .running).process(locations: locations, heartRates: rates, workoutStart: TestRoutes.start)
    }

    @Test func availableMetricsDependOnData() {
        #expect(RouteMetric.available(in: track(heartRate: true, climb: 50)) == [.pace, .heartRate, .elevation])
        #expect(RouteMetric.available(in: track(heartRate: false, climb: 0)) == [.pace])
    }

    @Test func samplingKeepsEndpointsAndSpacing() {
        let track = track()
        let indices = RouteSampling.indices(in: track, segment: track.segments[0], spacing: 50)
        #expect(indices.first == 0)
        #expect(indices.last == track.count - 1)
        for (a, b) in zip(indices, indices.dropFirst().dropLast()) {
            #expect(track.distances[b] - track.distances[a] >= 50)
        }
    }

    @Test func chartSamplesAreBoundedAndOrdered() {
        let samples = RouteSampling.chartSamples(for: track(seconds: 3000), maxPoints: 300)
        #expect(samples.count <= 302)
        #expect(samples.map(\.distanceKm) == samples.map(\.distanceKm).sorted())
        #expect(samples.first?.distanceKm == 0)
        #expect(samples.allSatisfy { $0.heartRate == 140 })
    }

    @Test func mapContentHasOneColorPerPoint() {
        let visualization = RouteVisualization(track: track())
        let content = visualization.mapContent(coloredBy: .pace)
        #expect(!content.segments.isEmpty)
        for segment in content.segments {
            #expect(segment.colors.count == segment.coordinates.count)
        }
        #expect(content.isLoop == false)
    }

    @Test func pacesForCharts() {
        let sample = ChartSample(index: 0, distanceKm: 0, elevation: 0, speed: 1000.0 / 300, heartRate: nil)
        let pace = RouteMetric.pace.chartValue(sample, style: .minutesPerKilometer)
        #expect(abs((pace ?? 0) - 300) < 0.001)

        let stopped = ChartSample(index: 0, distanceKm: 0, elevation: 0, speed: 0.1, heartRate: nil)
        #expect(RouteMetric.pace.chartValue(stopped, style: .minutesPerKilometer) == nil)
        #expect(RouteMetric.heartRate.chartValue(stopped, style: .minutesPerKilometer) == nil)
    }

    @Test func smoothingSkipsUnknownValues() {
        let smoothed = RouteSampling.smoothed([1, nil, 3, 5, nil], window: 3, segments: [0..<5])
        #expect(smoothed == [1, nil, 4, 4, nil])
    }

    @Test func nearestSample() {
        let visualization = RouteVisualization(track: track())
        let sample = visualization.sample(nearestKm: 0.9)
        #expect(abs((sample?.distanceKm ?? 0) - 0.9) < 0.02)
    }
}

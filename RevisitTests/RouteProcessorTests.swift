import Foundation
import Testing
@testable import Revisit

struct RouteProcessorTests {
    private let processor = RouteProcessor(kind: .running)

    @Test func straightKilometerMeasuresAboutOneKilometer() {
        let locations = TestRoutes.straightLine(seconds: 333, speed: 3)
        let track = processor.process(locations: locations, heartRates: [], workoutStart: TestRoutes.start)

        #expect(track.count == locations.count)
        #expect(abs(track.totalDistance - 999) < 1)
        #expect(track.segmentStarts == [0])
        #expect(track.times.first == 0)
        #expect(track.times.last == 333)
    }

    @Test func dropsInaccurateAndInvalidPoints() {
        var locations = TestRoutes.straightLine(seconds: 10)
        locations[3].horizontalAccuracy = 80
        locations[6].horizontalAccuracy = -1

        let kept = processor.filter(locations)
        #expect(kept.count == locations.count - 2)
    }

    @Test func dropsGPSJumps() {
        var locations = TestRoutes.straightLine(seconds: 20)
        let jumped = Geo.offset(locations[10].coordinate, north: 500, east: 0)
        locations[10].latitude = jumped.latitude
        locations[10].longitude = jumped.longitude

        let kept = processor.filter(locations)
        #expect(kept.count == locations.count - 1)
        #expect(!kept.contains { $0.timestamp == locations[10].timestamp })
    }

    @Test func persistentJumpIsEventuallyAcceptedAsNewPosition() {
        // The runner really is 500 m away from here on (e.g. the first fix was wrong).
        let first = TestRoutes.straightLine(seconds: 5)
        let moved = TestRoutes.straightLine(
            seconds: 20,
            startOffset: 6,
            from: Geo.offset(TestRoutes.origin, north: 500, east: 0)
        )
        let kept = processor.filter(first + moved)
        #expect(kept.count > first.count + 10)
    }

    @Test func splitsSegmentsOnPausesAndSkipsPauseDistance() {
        let before = TestRoutes.straightLine(seconds: 100, speed: 3)
        // 60 s pause, then resume 200 m further east.
        let after = TestRoutes.straightLine(
            seconds: 100,
            speed: 3,
            startOffset: 160,
            from: Geo.offset(TestRoutes.origin, north: 0, east: 500)
        )
        let track = processor.process(locations: before + after, heartRates: [], workoutStart: TestRoutes.start)

        #expect(track.segmentStarts == [0, before.count])
        #expect(track.segments == [0..<before.count, before.count..<(before.count + after.count)])
        #expect(abs(track.totalDistance - 600) < 1)
    }

    @Test func elevationGainIgnoresNoise() {
        // Climbs 20 m while wobbling ±1 m every second.
        let locations = TestRoutes.straightLine(seconds: 40) { second in
            100 + Double(second) * 0.5 + (second.isMultiple(of: 2) ? 1 : -1)
        }
        let track = processor.process(locations: locations, heartRates: [], workoutStart: TestRoutes.start)
        #expect(abs(track.elevationGain - 20) < 4)
    }

    @Test func flatNoisyRouteHasNoElevationGain() {
        let locations = TestRoutes.straightLine(seconds: 60) { second in
            50 + (second.isMultiple(of: 2) ? 1.5 : -1.5)
        }
        let track = processor.process(locations: locations, heartRates: [], workoutStart: TestRoutes.start)
        #expect(track.elevationGain == 0)
    }

    @Test func interpolatesHeartRate() {
        let start = TestRoutes.start
        let samples = [
            HeartRateSample(date: start, bpm: 100),
            HeartRateSample(date: start + 10, bpm: 120),
        ]
        let rates = RouteProcessor.interpolateHeartRates(
            at: [start, start + 5, start + 10, start + 25, start + 100],
            samples: samples,
            maxGap: 30
        )
        #expect(rates == [100, 110, 120, 120, ProcessedTrack.unknownHeartRate])
    }

    @Test func heartRateUnknownWithoutSamples() {
        let track = processor.process(locations: TestRoutes.straightLine(seconds: 5), heartRates: [], workoutStart: TestRoutes.start)
        #expect(!track.hasHeartRate)
        #expect(track.heartRates.allSatisfy { $0 == ProcessedTrack.unknownHeartRate })
    }

    @Test func tooFewPointsGiveEmptyTrack() {
        let track = processor.process(locations: TestRoutes.straightLine(seconds: 0), heartRates: [], workoutStart: TestRoutes.start)
        #expect(track.isEmpty)
    }

    @Test func unsortedInputIsSorted() {
        let locations = TestRoutes.straightLine(seconds: 30)
        let track = processor.process(locations: locations.shuffled(), heartRates: [], workoutStart: TestRoutes.start)
        #expect(track.times == track.times.sorted())
        #expect(abs(track.totalDistance - 90) < 0.5)
    }

    @Test func trackSurvivesEncoding() throws {
        let track = processor.process(
            locations: TestRoutes.straightLine(seconds: 50),
            heartRates: [HeartRateSample(date: TestRoutes.start + 20, bpm: 140)],
            workoutStart: TestRoutes.start
        )
        let decoded = try ProcessedTrack.decode(track.encoded())
        #expect(decoded == track)
    }
}

import Foundation
import Testing
@testable import Revisit

struct ReplayTimelineTests {
    private let processor = RouteProcessor(kind: .running)

    private func eastbound(seconds: Int = 300) -> ProcessedTrack {
        processor.process(locations: TestRoutes.straightLine(seconds: seconds, speed: 3), heartRates: [], workoutStart: TestRoutes.start)
    }

    @Test func progressMapsToDistance() {
        let timeline = ReplayTimeline(track: eastbound())
        #expect(timeline.position(atProgress: 0).distance == 0)
        #expect(abs(timeline.position(atProgress: 0.5).distance - 450) < 0.5)
        #expect(abs(timeline.position(atProgress: 1).distance - 900) < 0.5)
        #expect(timeline.position(atProgress: 1).index == timeline.track.count - 1)
    }

    @Test func progressIsClamped() {
        let timeline = ReplayTimeline(track: eastbound())
        #expect(timeline.position(atProgress: -1) == timeline.position(atProgress: 0))
        #expect(timeline.position(atProgress: 2) == timeline.position(atProgress: 1))
    }

    @Test func pausesDoNotTakeReplayTime() {
        let before = TestRoutes.straightLine(seconds: 100, speed: 3)
        let after = TestRoutes.straightLine(
            seconds: 100, speed: 3, startOffset: 1000,
            from: Geo.offset(TestRoutes.origin, north: 0, east: 300)
        )
        let track = processor.process(locations: before + after, heartRates: [], workoutStart: TestRoutes.start)
        let timeline = ReplayTimeline(track: track)

        // 200 s of moving time; the 900 s pause is skipped.
        #expect(timeline.totalMovingTime == 200)
        #expect(abs(timeline.position(atProgress: 0.5).distance - 300) < 1)
    }

    @Test func coordinateAtDistanceInterpolates() {
        let timeline = ReplayTimeline(track: eastbound())
        let point = timeline.coordinate(atDistance: 100)
        #expect(abs(Geo.distance(TestRoutes.origin, point) - 100) < 0.5)
        #expect(timeline.coordinate(atDistance: -50) == timeline.track.coordinate(at: 0))
    }

    @Test func lastIndexNotAbove() {
        let values: [Double] = [0, 1, 1, 2, 5]
        #expect(ReplayTimeline.lastIndex(in: values, notAbove: 0) == 0)
        #expect(ReplayTimeline.lastIndex(in: values, notAbove: 1.5) == 2)
        #expect(ReplayTimeline.lastIndex(in: values, notAbove: 4.9) == 3)
        #expect(ReplayTimeline.lastIndex(in: values, notAbove: 99) == 4)
    }
}

struct CameraDirectorTests {
    private func director(for locations: [RawLocation]) -> CameraDirector {
        let track = RouteProcessor(kind: .running).process(locations: locations, heartRates: [], workoutStart: TestRoutes.start)
        return CameraDirector(timeline: ReplayTimeline(track: track))
    }

    @Test func followCameraLooksAlongTheRoute() {
        let director = director(for: TestRoutes.straightLine(seconds: 600, speed: 3))
        let camera = director.camera(atProgress: 0.5)
        #expect(abs(camera.heading - 90) < 1)
        #expect(camera.pitch == director.options.followPitch)
        #expect(camera.distance == director.options.followDistance)
    }

    @Test func introStartsAtOverviewAndOutroEndsTilted() {
        let director = director(for: TestRoutes.straightLine(seconds: 600, speed: 3))
        let first = director.camera(atProgress: 0)
        #expect(first.center == director.overview.center)
        #expect(abs(first.distance - director.overview.distance) < 0.001)
        #expect(first.pitch == 0)
        let last = director.camera(atProgress: 1)
        #expect(last.pitch == director.options.outroPitch)
        #expect(abs(last.distance - director.overview.distance) < 0.001)
    }

    @Test func cameraIsContinuousAcrossPhases() {
        let director = director(for: TestRoutes.straightLine(seconds: 600, speed: 3))
        let intro = director.options.introFraction
        let before = director.camera(atProgress: intro - 0.0001)
        let after = director.camera(atProgress: intro + 0.0001)
        #expect(Geo.distance(before.center, after.center) < 5)
        #expect(abs(before.heading - after.heading) < 1)
    }

    @Test func headingTurnsSmoothlyAroundACorner() {
        // East for 600 m, then north for 600 m.
        let east = TestRoutes.straightLine(seconds: 200, speed: 3)
        let corner = Geo.offset(TestRoutes.origin, north: 0, east: 600)
        let north = (1...200).map { second in
            let point = Geo.offset(corner, north: Double(second) * 3, east: 0)
            return RawLocation(latitude: point.latitude, longitude: point.longitude, altitude: 10,
                               timestamp: TestRoutes.start + 200 + TimeInterval(second), speed: 3, horizontalAccuracy: 5)
        }
        let director = director(for: east + north)

        var previous = director.smoothedHeading(atDistance: 0)
        for meters in stride(from: 10.0, through: 1200, by: 10) {
            let heading = director.smoothedHeading(atDistance: meters)
            #expect(abs(heading - previous) < 10, "heading jumped at \(meters) m")
            previous = heading
        }
        #expect(abs(director.smoothedHeading(atDistance: 100) - 90) < 2)
        #expect(director.smoothedHeading(atDistance: 1100) < 2 || director.smoothedHeading(atDistance: 1100) > 358)
    }

    @Test func turnaroundSwingsSmoothlyInsteadOfFlipping() {
        // Out 600 m east, then straight back west over the same path.
        let out = TestRoutes.straightLine(seconds: 200, speed: 3)
        let turn = Geo.offset(TestRoutes.origin, north: 0, east: 600)
        let back = (1...200).map { second in
            let point = Geo.offset(turn, north: 0, east: -Double(second) * 3)
            return RawLocation(latitude: point.latitude, longitude: point.longitude, altitude: 10,
                               timestamp: TestRoutes.start + 200 + TimeInterval(second), speed: 3, horizontalAccuracy: 5)
        }
        let director = director(for: out + back)
        let maxStep = director.options.maxTurnPerRoute / Double(CameraDirector.headingSamples)

        for (a, b) in zip(director.headings, director.headings.dropFirst()) {
            #expect(abs(CameraDirector.signedDelta(from: a, to: b)) <= maxStep + 0.001)
        }
        #expect(abs(director.heading(atRouteProgress: 0.2) - 90) < 2)
        #expect(abs(director.heading(atRouteProgress: 0.9) - 270) < 2)
    }

    @Test func blendAngleTakesTheShortWay() {
        #expect(abs(CameraDirector.blendAngle(350, 10, t: 0.5) - 0) < 0.001 || abs(CameraDirector.blendAngle(350, 10, t: 0.5) - 360) < 0.001)
        #expect(abs(CameraDirector.blendAngle(10, 350, t: 0.25) - 5) < 0.001)
        #expect(abs(CameraDirector.blendAngle(90, 180, t: 0.5) - 135) < 0.001)
    }

    @Test func routeProgressOnlyMovesDuringFollowPhase() {
        let director = director(for: TestRoutes.straightLine(seconds: 100))
        #expect(director.routeProgress(atProgress: 0.05) == 0)
        #expect(director.routeProgress(atProgress: 0.95) == 1)
        #expect(abs(director.routeProgress(atProgress: 0.51) - 0.5) < 0.001)
    }
}

import Foundation

/// Where the map camera is. Engine-agnostic; each renderer converts it to its own camera type.
nonisolated struct CameraState: Equatable, Sendable {
    var center: Coordinate
    /// Meters from the camera to `center`.
    var distance: Double
    /// Degrees from straight down.
    var pitch: Double
    /// Degrees clockwise from north.
    var heading: Double
}

/// Decides the camera for every moment of the replay.
///
/// A pure function of progress, so scrubbing backwards gives exactly the same shot:
/// 1. Intro — from an overview of the whole route, swoop down behind the start.
/// 2. Follow — chase the runner, looking along the route ahead.
/// 3. Outro — pull back up to a tilted overview.
nonisolated struct CameraDirector: Sendable {
    struct Options: Sendable {
        var followDistance: Double = 800
        /// Not too steep: at a shallow angle a ridge between camera and runner hides the runner.
        var followPitch: Double = 55
        /// Heading is averaged over this stretch of route ahead (meters), so it turns early and smoothly.
        var lookAhead: Double = 300
        var lookBehind: Double = 100
        /// Fastest the camera may turn, in degrees per whole route (180° takes 6% of the route).
        var maxTurnPerRoute: Double = 3000
        var introFraction: Double = 0.12
        var outroFraction: Double = 0.10
        var outroPitch: Double = 45
    }

    static let headingSamples = 600

    let timeline: ReplayTimeline
    let options: Options
    let overview: CameraState
    /// Camera heading at `headingSamples + 1` evenly spaced route-progress values.
    let headings: [Double]

    init(timeline: ReplayTimeline, options: Options = Options()) {
        self.timeline = timeline
        self.options = options
        overview = Self.overview(of: timeline.track)
        headings = Self.headingTable(timeline: timeline, options: options)
    }

    /// Replay progress (0...1) → route progress (0...1). The route only moves during the follow phase.
    func routeProgress(atProgress progress: Double) -> Double {
        let followLength = 1 - options.introFraction - options.outroFraction
        return min(1, max(0, (progress - options.introFraction) / followLength))
    }

    func camera(atProgress progress: Double) -> CameraState {
        let p = min(1, max(0, progress))
        if p < options.introFraction {
            let start = followCamera(atRouteProgress: 0)
            return Self.blend(overview, start, t: Self.ease(p / options.introFraction))
        }
        if p > 1 - options.outroFraction {
            let end = followCamera(atRouteProgress: 1)
            var finale = overview
            finale.pitch = options.outroPitch
            finale.heading = end.heading
            let t = (p - (1 - options.outroFraction)) / options.outroFraction
            return Self.blend(end, finale, t: Self.ease(t))
        }
        return followCamera(atRouteProgress: routeProgress(atProgress: p))
    }

    func followCamera(atRouteProgress routeProgress: Double) -> CameraState {
        // Centered on the runner, which keeps it clear of the stats and controls at the screen edges.
        CameraState(
            center: timeline.position(atProgress: routeProgress).coordinate,
            distance: options.followDistance,
            pitch: options.followPitch,
            heading: heading(atRouteProgress: routeProgress)
        )
    }

    /// Looks up the precomputed heading table.
    func heading(atRouteProgress routeProgress: Double) -> Double {
        let position = min(1, max(0, routeProgress)) * Double(headings.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, headings.count - 1)
        return Self.blendAngle(headings[lower], headings[upper], t: position - Double(lower))
    }

    /// Distance-weighted circular mean of the route's direction around `distance`.
    func smoothedHeading(atDistance distance: Double) -> Double {
        Self.routeDirection(timeline: timeline, options: options, atDistance: distance).heading
    }

    /// The route's mean direction around `distance`, and how consistent it is (0...1):
    /// near 1 on a straight, near 0 at a turnaround where directions cancel out.
    static func routeDirection(timeline: ReplayTimeline, options: Options, atDistance distance: Double) -> (heading: Double, consistency: Double) {
        var x = 0.0
        var y = 0.0
        var totalWeight = 0.0
        let step = 25.0
        let chord = options.lookAhead / 2
        for offset in stride(from: -options.lookBehind, through: options.lookAhead - chord, by: step) {
            let a = timeline.coordinate(atDistance: distance + offset)
            let b = timeline.coordinate(atDistance: distance + offset + chord)
            let weight = Geo.distance(a, b)
            guard weight > 1 else { continue }
            let bearing = Geo.bearing(from: a, to: b).radians
            x += cos(bearing) * weight
            y += sin(bearing) * weight
            totalWeight += weight
        }
        guard totalWeight > 0, x != 0 || y != 0 else { return (0, 0) }
        let heading = (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
        return (heading, hypot(x, y) / totalWeight)
    }

    /// Heading at evenly spaced route-progress samples. Where the route's direction is
    /// ambiguous (a turnaround) the camera holds its heading, and it never turns faster than
    /// `maxTurnPerRoute`, so hairpins become a smooth swing instead of a flip.
    static func headingTable(timeline: ReplayTimeline, options: Options) -> [Double] {
        let count = headingSamples
        let maxStep = options.maxTurnPerRoute / Double(count)
        var table: [Double] = []
        table.reserveCapacity(count + 1)

        for sample in 0...count {
            let distance = timeline.position(atProgress: Double(sample) / Double(count)).distance
            let direction = routeDirection(timeline: timeline, options: options, atDistance: distance)
            guard let previous = table.last else {
                table.append(direction.heading)
                continue
            }
            let target = direction.consistency > 0.5 ? direction.heading : previous
            let delta = min(maxStep, max(-maxStep, signedDelta(from: previous, to: target)))
            table.append((previous + delta + 360).truncatingRemainder(dividingBy: 360))
        }
        return smoothedAngles(table, window: 9)
    }

    /// Circular moving average, to round off the start and end of rate-limited turns.
    static func smoothedAngles(_ angles: [Double], window: Int) -> [Double] {
        let half = window / 2
        return angles.indices.map { index in
            var x = 0.0
            var y = 0.0
            for j in max(0, index - half)...min(angles.count - 1, index + half) {
                x += cos(angles[j].radians)
                y += sin(angles[j].radians)
            }
            return (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
        }
    }

    /// Shortest signed rotation from `a` to `b`, in -180...180.
    static func signedDelta(from a: Double, to b: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    // MARK: - Helpers

    static func overview(of track: ProcessedTrack) -> CameraState {
        guard let box = Geo.boundingBox(of: track.coordinates) else {
            return CameraState(center: Coordinate(latitude: 0, longitude: 0), distance: 1000, pitch: 0, heading: 0)
        }
        let height = Geo.distance(
            Coordinate(latitude: box.minLatitude, longitude: box.center.longitude),
            Coordinate(latitude: box.maxLatitude, longitude: box.center.longitude)
        )
        let width = Geo.distance(
            Coordinate(latitude: box.center.latitude, longitude: box.minLongitude),
            Coordinate(latitude: box.center.latitude, longitude: box.maxLongitude)
        )
        // Portrait screen: width is the tighter fit, so it gets more room.
        let distance = max(width * 2.6, height * 1.6, 800)
        return CameraState(center: box.center, distance: distance, pitch: 0, heading: 0)
    }

    static func blend(_ a: CameraState, _ b: CameraState, t: Double) -> CameraState {
        CameraState(
            center: Geo.interpolate(a.center, b.center, fraction: t),
            // Geometric zoom feels even; linear zoom rushes at the end.
            distance: exp(log(a.distance) + (log(b.distance) - log(a.distance)) * t),
            pitch: a.pitch + (b.pitch - a.pitch) * t,
            heading: blendAngle(a.heading, b.heading, t: t)
        )
    }

    /// Interpolates along the shorter way around the circle.
    static func blendAngle(_ a: Double, _ b: Double, t: Double) -> Double {
        (a + signedDelta(from: a, to: b) * t + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smoothstep.
    static func ease(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return t * t * (3 - 2 * t)
    }
}

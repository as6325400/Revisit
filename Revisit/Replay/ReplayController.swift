import Observation
import QuartzCore
import UIKit

/// Anything that can draw replay frames: Mapbox when a token is configured, MapKit otherwise.
protocol ReplayRendering: AnyObject {
    var view: UIView { get }
    func render(camera: CameraState, runner: Coordinate)
    /// Loads whatever is needed along these cameras (map tiles) ahead of playback.
    func preload(_ cameras: [CameraState], progress: @escaping @MainActor @Sendable (Double) -> Void) async
}

/// Plays the replay: advances progress on every display refresh and hands each frame
/// straight to the renderer. SwiftUI only sees throttled updates, so the overlays don't
/// re-render 60 times a second.
@Observable
final class ReplayController {
    static let durationChoices: [TimeInterval] = [15, 30, 60]
    private static let uiUpdateInterval: CFTimeInterval = 1.0 / 12

    let visualization: RouteVisualization
    let content: RouteMapContent
    let director: CameraDirector

    /// Progress as shown in the UI; lags the rendered frame by at most `uiUpdateInterval`.
    private(set) var progress: Double = 0
    private(set) var isPlaying = false
    /// 0...1 while map tiles are preloading, nil otherwise.
    private(set) var loadingProgress: Double?
    /// Real seconds the whole replay takes.
    var duration: TimeInterval = 30

    @ObservationIgnored weak var renderer: (any ReplayRendering)?
    @ObservationIgnored private var frameProgress: Double = 0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    @ObservationIgnored private var lastUIUpdate: CFTimeInterval = 0
    @ObservationIgnored private var startTask: Task<Void, Never>?

    #if DEBUG
    @ObservationIgnored private var stats = FrameStats()
    #endif

    init(visualization: RouteVisualization, metric: RouteMetric) {
        self.visualization = visualization
        content = visualization.mapContent(coloredBy: metric)
        director = CameraDirector(timeline: ReplayTimeline(track: visualization.track))
    }

    /// Where the runner is, at the UI's progress.
    var position: ReplayTimeline.Position {
        runnerPosition(at: progress)
    }

    // MARK: Lifecycle

    /// Preloads the map along the route, then plays.
    func start() {
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.preloadThenPlay()
        }
    }

    private func preloadThenPlay() async {
        renderCurrentFrame()
        loadingProgress = 0
        #if DEBUG
        let began = ContinuousClock.now
        #endif
        await renderer?.preload(preloadCameras()) { [weak self] fraction in
            self?.loadingProgress = fraction
        }
        #if DEBUG
        print("REPLAYSTATS preload finished in \(ContinuousClock.now - began)")
        #endif
        guard !Task.isCancelled else { return }
        loadingProgress = nil
        renderCurrentFrame()
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        play()
    }

    func skipPreload() {
        startTask?.cancel()
        startTask = nil
        loadingProgress = nil
        play()
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        pause()
    }

    // MARK: Playback

    func play() {
        if frameProgress >= 1 { seek(to: 0) }
        isPlaying = true
        startDisplayLink()
    }

    func pause() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        progress = frameProgress
        #if DEBUG
        stats.report(renderer: renderer)
        #endif
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func seek(to newProgress: Double) {
        frameProgress = min(1, max(0, newProgress))
        progress = frameProgress
        renderCurrentFrame()
    }

    func renderCurrentFrame() {
        renderer?.render(camera: director.camera(atProgress: frameProgress), runner: runnerPosition(at: frameProgress).coordinate)
    }

    // MARK: Private

    private func runnerPosition(at progress: Double) -> ReplayTimeline.Position {
        director.timeline.position(atProgress: director.routeProgress(atProgress: progress))
    }

    /// Cameras spread along the whole replay, roughly one per 400 m of route.
    private func preloadCameras() -> [CameraState] {
        let stops = min(20, max(6, Int(visualization.track.totalDistance / 400)))
        return (0...stops).map { director.camera(atProgress: Double($0) / Double(stops)) }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] link in self?.tick(link) }
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        if let last = lastTimestamp {
            let elapsed = link.timestamp - last
            frameProgress = min(1, frameProgress + elapsed / duration)
            #if DEBUG
            stats.record(frameTime: elapsed, expected: link.targetTimestamp - link.timestamp)
            #endif
        }
        renderCurrentFrame()

        if link.timestamp - lastUIUpdate >= Self.uiUpdateInterval || frameProgress >= 1 {
            progress = frameProgress
            lastUIUpdate = link.timestamp
        }
        if frameProgress >= 1 { pause() }
    }
}

/// `CADisplayLink` needs an Objective-C target; this forwards to a closure.
private final class DisplayLinkTarget: NSObject {
    private let handler: (CADisplayLink) -> Void

    init(_ handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
    }

    @objc func fire(_ link: CADisplayLink) {
        handler(link)
    }
}

#if DEBUG
/// Counts dropped frames during playback and prints a summary, readable from the Mac with
/// `xcrun devicectl device process launch --console`.
private struct FrameStats {
    private var frames = 0
    private var dropped = 0
    private var longest: CFTimeInterval = 0

    mutating func record(frameTime: CFTimeInterval, expected: CFTimeInterval) {
        frames += 1
        if frameTime > max(expected, 1.0 / 60) * 1.5 { dropped += 1 }
        longest = max(longest, frameTime)
    }

    mutating func report(renderer: (any ReplayRendering)?) {
        guard frames > 0 else { return }
        var line = "REPLAYSTATS frames=\(frames) dropped=\(dropped) longest=\(Int(longest * 1000))ms"
        if let mapKit = renderer as? MapKitReplayRenderer {
            line += " mapRenders=\(mapKit.renderStarts) incompleteRenders=\(mapKit.incompleteRenders)"
        }
        print(line)
        self = FrameStats()
    }
}
#endif

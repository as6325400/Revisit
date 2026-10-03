import AVFoundation
import UIKit

/// Renders the replay frame by frame into an MP4 (1080×1920, 9:16, 30 fps).
///
/// Unlike screen recording, every frame waits until the map is fully drawn, so the video
/// has no half-loaded tiles no matter how slow the device or network is.
final class ReplayVideoExporter {
    static let size = CGSize(width: 1080, height: 1920)
    static let framesPerSecond: Int32 = 30
    /// The last frame is held this long so the video doesn't end abruptly.
    static let holdSeconds = 1.5

    private let controller: ReplayController
    private let renderer: MapboxReplayRenderer
    private let kind: WorkoutKind

    init(controller: ReplayController, renderer: MapboxReplayRenderer, kind: WorkoutKind) {
        self.controller = controller
        self.renderer = renderer
        self.kind = kind
    }

    /// Writes the video and returns its file URL. Cancelling the task stops the export.
    func export(duration: TimeInterval, progress: (Double) -> Void) async throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "Revisit-\(Int(Date.now.timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(Self.size.width),
            AVVideoHeightKey: Int(Self.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(Self.framesPerSecond),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(Self.size.width),
            kCVPixelBufferHeightKey as String: Int(Self.size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let fps = Double(Self.framesPerSecond)
        let movingFrames = max(2, Int(duration * fps))
        let totalFrames = movingFrames + Int(Self.holdSeconds * fps)

        do {
            var lastFrame: CVPixelBuffer?
            for frame in 0..<totalFrames {
                try Task.checkCancellation()

                if frame < movingFrames {
                    let replayProgress = Double(frame) / Double(movingFrames - 1)
                    let director = controller.director
                    let position = director.timeline.position(atProgress: director.routeProgress(atProgress: replayProgress))
                    renderer.render(camera: director.camera(atProgress: replayProgress), runner: position.coordinate)
                    await renderer.waitUntilIdle(timeout: .seconds(3))
                    lastFrame = try autoreleasepool { try makeFrame(position: position, adaptor: adaptor) }
                }
                guard let buffer = lastFrame else { throw ExportError.snapshotFailed }

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let time = CMTime(value: CMTimeValue(frame), timescale: Self.framesPerSecond)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? ExportError.writerFailed
                }
                progress(Double(frame + 1) / Double(totalFrames))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.writerFailed }
        return url
    }

    // MARK: Frame composition

    private func makeFrame(position: ReplayTimeline.Position, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        let map = try renderer.snapshot()

        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writerFailed }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw ExportError.writerFailed }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(Self.size.width),
            height: Int(Self.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw ExportError.writerFailed }

        // Draw with UIKit's top-left origin.
        context.translateBy(x: 0, y: Self.size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        map.draw(in: CGRect(origin: .zero, size: Self.size))
        drawOverlay(at: position)
        return buffer
    }

    /// Stats card and attribution, laid out in a 360×640 point space scaled ×3.
    private func drawOverlay(at position: ReplayTimeline.Position) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x: Self.size.width / 360, y: Self.size.height / 640)

        let track = controller.visualization.track
        let speed = track.speeds[position.index]
        let heartRate = track.heartRates[position.index]

        var detail = "\(Formatters.duration(position.movingTime))   \(Formatters.pace(speed: speed, style: kind.paceStyle))"
        if heartRate >= 0 { detail += "   ♥ \(Formatters.heartRate(heartRate))" }

        let title = NSAttributedString(string: kind.displayName, attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.white,
        ])
        let distance = NSAttributedString(string: Formatters.distance(position.distance), attributes: [
            .font: UIFont.systemFont(ofSize: 28, weight: .bold).rounded, .foregroundColor: UIColor.white,
        ])
        let details = NSAttributedString(string: detail, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.white,
        ])

        let padding: CGFloat = 12
        let width = max(title.size().width, distance.size().width, details.size().width) + padding * 2
        let height = title.size().height + distance.size().height + details.size().height + padding * 2 + 4
        let card = CGRect(x: 16, y: 20, width: width, height: height)
        UIColor.black.withAlphaComponent(0.5).setFill()
        UIBezierPath(roundedRect: card, cornerRadius: 14).fill()

        var y = card.minY + padding
        for line in [title, distance, details] {
            line.draw(at: CGPoint(x: card.minX + padding, y: y))
            y += line.size().height + 2
        }

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        let attribution = NSAttributedString(string: "© Mapbox © OpenStreetMap © Maxar", attributes: [
            .font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.white.withAlphaComponent(0.85), .shadow: shadow,
        ])
        attribution.draw(at: CGPoint(x: 360 - attribution.size().width - 10, y: 640 - attribution.size().height - 10))

        let brand = NSAttributedString(string: "Revisit", attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .heavy), .foregroundColor: UIColor.white, .shadow: shadow,
        ])
        brand.draw(at: CGPoint(x: 360 - brand.size().width - 16, y: 24))
    }

    enum ExportError: LocalizedError {
        case writerFailed
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .writerFailed: "無法寫入影片檔。"
            case .snapshotFailed: "無法擷取地圖畫面。"
            }
        }
    }
}

private extension UIFont {
    var rounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

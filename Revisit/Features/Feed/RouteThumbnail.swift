import MapKit
import SwiftUI

/// Small static map with the route drawn on it, for list rows.
struct RouteThumbnail: View {
    let workoutID: UUID
    let coordinates: [Coordinate]
    let status: RouteStatus
    /// Shown instead of a map for workouts that never have a route (indoor, pool).
    var fallbackSymbol: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if status == .pending {
                    ProgressView()
                } else if status != .ready {
                    Image(systemName: fallbackSymbol ?? "location.slash")
                        .font(fallbackSymbol == nil ? .body : .title)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: "\(workoutID)-\(coordinates.count)-\(colorScheme)-\(proxy.size.width)x\(proxy.size.height)") {
                image = await RouteSnapshotRenderer.shared.image(
                    id: workoutID,
                    coordinates: coordinates,
                    size: proxy.size,
                    scale: displayScale,
                    dark: colorScheme == .dark
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Renders and caches route snapshots with `MKMapSnapshotter`.
final class RouteSnapshotRenderer {
    static let shared = RouteSnapshotRenderer()

    private let cache = NSCache<NSString, UIImage>()

    func image(id: UUID, coordinates: [Coordinate], size: CGSize, scale: CGFloat, dark: Bool) async -> UIImage? {
        guard coordinates.count >= 2, size.width > 0, size.height > 0 else { return nil }
        let key = "\(id.uuidString)-\(Int(size.width))x\(Int(size.height))@\(scale)-\(dark)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let options = MKMapSnapshotter.Options()
        options.region = MapGeometry.region(fitting: coordinates, aspectRatio: size.width / size.height)
        options.size = size
        options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection { traits in
            traits.displayScale = scale
            traits.userInterfaceStyle = dark ? .dark : .light
        }

        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            snapshot.image.draw(at: .zero)

            let path = UIBezierPath()
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: CLLocationCoordinate2D(coordinate))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round

            UIColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 5
            path.stroke()

            Theme.routeUIColor.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

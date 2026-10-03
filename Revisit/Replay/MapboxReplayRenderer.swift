import MapboxMaps
import UIKit

/// Draws replay frames with Mapbox: satellite imagery on 3D terrain, and the route as a
/// GPU line layer (so it never flickers while the camera moves). Before playback the
/// tiles around the route are downloaded into the tile store, so nothing loads mid-flight.
final class MapboxReplayRenderer: ReplayRendering {
    /// False when no Mapbox token is configured (see Config/Secrets.example.xcconfig).
    static var isConfigured: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String)?.hasPrefix("pk.") == true
    }

    let mapView: MapView
    var view: UIView { mapView }

    private let content: RouteMapContent
    private var cancelables = Set<AnyCancelable>()
    private var isStyleReady = false
    private var pendingFrame: (camera: CameraState, runner: Coordinate)?

    private static let terrainSourceID = "revisit-terrain"
    private static let runnerSourceID = "revisit-runner"
    private static let terrainTileset = "mapbox://mapbox.mapbox-terrain-dem-v1"
    private static let style = MapStyle.standardSatellite(
        showPointOfInterestLabels: false,
        showTransitLabels: false,
        showRoadLabels: false
    )

    init(content: RouteMapContent) {
        self.content = content
        mapView = MapView(frame: .zero, mapInitOptions: MapInitOptions(mapStyle: Self.style))
        // The camera is scripted; user gestures would fight it.
        mapView.isUserInteractionEnabled = false
        mapView.ornaments.options.scaleBar.visibility = .hidden
        mapView.ornaments.options.compass.visibility = .hidden

        mapView.mapboxMap.onStyleLoaded.observeNext { [weak self] _ in
            self?.styleDidLoad()
        }.store(in: &cancelables)
    }

    // MARK: ReplayRendering

    func render(camera: CameraState, runner coordinate: Coordinate) {
        guard isStyleReady, mapView.bounds.height > 0 else {
            pendingFrame = (camera, coordinate)
            return
        }
        mapView.mapboxMap.setCamera(to: CameraOptions(
            center: CLLocationCoordinate2D(camera.center),
            zoom: Self.zoom(forDistance: camera.distance, latitude: camera.center.latitude, viewHeight: mapView.bounds.height),
            bearing: camera.heading,
            pitch: camera.pitch
        ))
        mapView.mapboxMap.updateGeoJSONSource(
            withId: Self.runnerSourceID,
            geoJSON: .geometry(.point(Point(CLLocationCoordinate2D(coordinate))))
        )
    }

    /// Downloads imagery, vector and terrain tiles around the route: medium-detail tiles in a
    /// corridor along it, coarse tiles for the wide area the tilted camera sees at the horizon.
    /// The finest zoom levels right under the camera still stream during playback; they're few.
    /// Regions are stored per route, so replaying a route later needs no download.
    func preload(_ cameras: [CameraState], progress: @escaping @MainActor @Sendable (Double) -> Void) async {
        let coordinates = content.segments.flatMap(\.coordinates)
        guard !coordinates.isEmpty else { return }

        let offline = OfflineManager()
        let tilesets = [Self.terrainTileset]
        let near = offline.createTilesetDescriptor(for: TilesetDescriptorOptions(styleURI: .standardSatellite, zoomRange: 13...16, tilesets: tilesets))
        let far = offline.createTilesetDescriptor(for: TilesetDescriptorOptions(styleURI: .standardSatellite, zoomRange: 8...12, tilesets: tilesets))

        let key = TileRegionCache.key(for: coordinates)
        let regions: [(id: String, geometry: Geometry, descriptor: TilesetDescriptor)] = [
            ("\(key)-far", .polygon(Self.area(around: coordinates, margin: 4000)), far),
            ("\(key)-near", .multiPoint(Self.corridor(along: coordinates, halfWidth: 300)), near),
        ]

        for (index, region) in regions.enumerated() {
            guard !Task.isCancelled else { return }
            guard let options = TileRegionLoadOptions(geometry: region.geometry, descriptors: [region.descriptor], acceptExpired: true) else { continue }
            let base = Double(index) / Double(regions.count)
            let share = 1 / Double(regions.count)
            await Self.load(region.id, options: options) { fraction in
                progress(base + fraction * share)
            }
        }
        guard !Task.isCancelled else { return }
        TileRegionCache.didUse(key)
        progress(1)
    }

    // MARK: Export

    /// Waits until the map has finished loading and drawing the current camera,
    /// or until `timeout`, whichever comes first.
    func waitUntilIdle(timeout: Duration) async {
        let waiter = OneShot()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.continuation = continuation
            waiter.token = mapView.mapboxMap.onMapIdle.observeNext { _ in waiter.fire() }
            Task {
                try? await Task.sleep(for: timeout)
                waiter.fire()
            }
        }
    }

    /// The rendered map including the runner and the Mapbox logo.
    func snapshot() throws -> UIImage {
        try mapView.snapshot(includeOverlays: true)
    }

    // MARK: Style

    private func styleDidLoad() {
        let map: MapboxMap = mapView.mapboxMap

        var terrainSource = RasterDemSource(id: Self.terrainSourceID)
        terrainSource.url = Self.terrainTileset
        terrainSource.tileSize = 514
        terrainSource.maxzoom = 14
        try? map.addSource(terrainSource)
        var terrain = Terrain(sourceId: Self.terrainSourceID)
        terrain.exaggeration = .constant(1.4)
        try? map.setTerrain(terrain)

        for (index, segment) in content.segments.enumerated() where segment.coordinates.count >= 2 {
            addRoute(segment, id: "revisit-route-\(index)")
        }
        addEndpoints()

        addRunner()

        isStyleReady = true
        if let frame = pendingFrame {
            pendingFrame = nil
            render(camera: frame.camera, runner: frame.runner)
        }
    }

    private func addRoute(_ segment: RouteMapContent.Segment, id: String) {
        var source = GeoJSONSource(id: id)
        source.data = .geometry(.lineString(LineString(segment.coordinates.map(CLLocationCoordinate2D.init))))
        source.lineMetrics = true
        try? mapView.mapboxMap.addSource(source)

        var casing = LineLayer(id: id + "-casing", source: id)
        casing.lineColor = .constant(StyleColor(UIColor.white.withAlphaComponent(0.9)))
        casing.lineWidth = .constant(9)
        casing.lineCap = .constant(.round)
        casing.lineJoin = .constant(.round)
        casing.lineEmissiveStrength = .constant(1)
        try? mapView.mapboxMap.addLayer(casing)

        var line = LineLayer(id: id + "-line", source: id)
        line.lineGradient = .expression(Self.gradient(segment.colors))
        line.lineWidth = .constant(5.5)
        line.lineCap = .constant(.round)
        line.lineJoin = .constant(.round)
        // Keep the line at full brightness regardless of the style's lighting.
        line.lineEmissiveStrength = .constant(1)
        try? mapView.mapboxMap.addLayer(line)
    }

    private func addEndpoints() {
        guard let start = content.start, let end = content.end else { return }
        var features = [Feature(geometry: Point(CLLocationCoordinate2D(start)))]
        features[0].properties = ["kind": "start"]
        if !content.isLoop {
            var finish = Feature(geometry: Point(CLLocationCoordinate2D(end)))
            finish.properties = ["kind": "finish"]
            features.append(finish)
        }
        var source = GeoJSONSource(id: "revisit-endpoints")
        source.data = .featureCollection(FeatureCollection(features: features))
        try? mapView.mapboxMap.addSource(source)

        var circles = CircleLayer(id: "revisit-endpoints", source: "revisit-endpoints")
        circles.circleRadius = .constant(7)
        circles.circleColor = .expression(Exp(.match) {
            Exp(.get) { "kind" }
            "finish"
            UIColor.systemRed
            UIColor.systemGreen
        })
        circles.circleStrokeColor = .constant(StyleColor(.white))
        circles.circleStrokeWidth = .constant(2.5)
        circles.circlePitchAlignment = .constant(.map)
        circles.circleEmissiveStrength = .constant(1)
        try? mapView.mapboxMap.addLayer(circles)
    }

    /// The runner is a circle layer draped on the terrain, like the route. (A UIKit view
    /// annotation gets hidden whenever Mapbox thinks terrain is in front of it.)
    private func addRunner() {
        var source = GeoJSONSource(id: Self.runnerSourceID)
        source.data = .geometry(.point(Point(CLLocationCoordinate2D(content.start ?? Coordinate(latitude: 0, longitude: 0)))))
        try? mapView.mapboxMap.addSource(source)

        var dot = CircleLayer(id: Self.runnerSourceID, source: Self.runnerSourceID)
        dot.circleRadius = .constant(9)
        dot.circleColor = .constant(StyleColor(Theme.routeUIColor))
        dot.circleStrokeColor = .constant(StyleColor(.white))
        dot.circleStrokeWidth = .constant(4)
        dot.circlePitchAlignment = .constant(.map)
        dot.circleEmissiveStrength = .constant(1)
        try? mapView.mapboxMap.addLayer(dot)
    }

    // MARK: Helpers

    /// A `line-progress` gradient with at most ~64 stops. Points are evenly spaced by distance,
    /// so index fraction ≈ line progress.
    private static func gradient(_ colors: [RGB]) -> Exp {
        guard colors.count > 1 else {
            let only = colors.first ?? ColorScale.unknown
            return Exp(operator: .literal, arguments: [.string(cssColor(only))])
        }
        let stride = max(1, colors.count / 64)
        var indices = Array(Swift.stride(from: 0, to: colors.count, by: stride))
        if indices.last != colors.count - 1 { indices.append(colors.count - 1) }

        var arguments: [Exp.Argument] = [.expression(Exp(.linear)), .expression(Exp(.lineProgress))]
        for index in indices {
            arguments.append(.number(Double(index) / Double(colors.count - 1)))
            arguments.append(.string(cssColor(colors[index])))
        }
        return Exp(operator: .interpolate, arguments: arguments)
    }

    private static func cssColor(_ rgb: RGB) -> String {
        "rgb(\(Int(rgb.red * 255)), \(Int(rgb.green * 255)), \(Int(rgb.blue * 255)))"
    }

    /// Mapbox zoom that puts the camera `distance` meters from the center.
    /// At zoom z a point is 78271.5·cos(lat)/2^z meters; the camera sits 1.5 × view height
    /// (in points) from the center for Mapbox's 36.87° field of view.
    static func zoom(forDistance distance: Double, latitude: Double, viewHeight: Double) -> Double {
        let metersPerPoint = distance / (1.5 * viewHeight)
        return log2(78271.517 * cos(latitude.radians) / metersPerPoint)
    }

    private static func area(around coordinates: [Coordinate], margin: Double) -> Polygon {
        let box = Geo.boundingBox(of: coordinates) ?? BoundingBox(minLatitude: 0, maxLatitude: 0, minLongitude: 0, maxLongitude: 0)
        let southWest = Geo.offset(Coordinate(latitude: box.minLatitude, longitude: box.minLongitude), north: -margin, east: -margin)
        let northEast = Geo.offset(Coordinate(latitude: box.maxLatitude, longitude: box.maxLongitude), north: margin, east: margin)
        let ring = [
            CLLocationCoordinate2D(latitude: southWest.latitude, longitude: southWest.longitude),
            CLLocationCoordinate2D(latitude: southWest.latitude, longitude: northEast.longitude),
            CLLocationCoordinate2D(latitude: northEast.latitude, longitude: northEast.longitude),
            CLLocationCoordinate2D(latitude: northEast.latitude, longitude: southWest.longitude),
            CLLocationCoordinate2D(latitude: southWest.latitude, longitude: southWest.longitude),
        ]
        return Polygon([ring])
    }

    /// Points on and beside the route; the tile region covers every tile containing one,
    /// which amounts to a band of detailed tiles along the route.
    private static func corridor(along coordinates: [Coordinate], halfWidth: Double) -> MultiPoint {
        var points: [CLLocationCoordinate2D] = []
        var lastKept: Coordinate?
        for coordinate in coordinates {
            if let last = lastKept, Geo.distance(last, coordinate) < 100 { continue }
            lastKept = coordinate
            for (north, east) in [(0.0, 0.0), (halfWidth, 0), (-halfWidth, 0), (0, halfWidth), (0, -halfWidth)] {
                points.append(CLLocationCoordinate2D(Geo.offset(coordinate, north: north, east: east)))
            }
        }
        return MultiPoint(points)
    }

    /// Loads one tile region; cancelling the calling task cancels the download.
    private static func load(_ id: String, options: TileRegionLoadOptions, progress: @escaping @MainActor @Sendable (Double) -> Void) async {
        let download = CancelableBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let handle = TileStore.default.loadTileRegion(forId: id, loadOptions: options) { update in
                    let required = Double(update.requiredResourceCount)
                    let fraction = required > 0 ? Double(update.completedResourceCount) / required : 0
                    Task { @MainActor in progress(fraction) }
                } completion: { result in
                    #if DEBUG
                    if case let .failure(error) = result { print("REPLAYSTATS tile region \(id) failed: \(error)") }
                    #endif
                    continuation.resume()
                }
                download.set(handle)
            }
        } onCancel: {
            download.cancel()
        }
    }
}

/// Holds a download handle that the cancellation handler (any thread) may cancel.
private nonisolated final class CancelableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: (any Cancelable)?
    private var isCancelled = false

    func set(_ cancelable: any Cancelable) {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { cancelable.cancel() } else { handle = cancelable }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        handle?.cancel()
    }
}

/// Remembers which routes have downloaded tile regions and deletes the least recently
/// used ones beyond `limit`, so storage doesn't grow without bound.
enum TileRegionCache {
    private static let defaultsKey = "tileRegionCache.lastUsed"
    private static let limit = 20

    /// Stable ID for a route, from its shape.
    static func key(for coordinates: [Coordinate]) -> String {
        guard let first = coordinates.first, let last = coordinates.last else { return "route-empty" }
        let parts = [first.latitude, first.longitude, last.latitude, last.longitude].map { String(format: "%.5f", $0) }
        return "route-" + (parts + [String(coordinates.count)]).joined(separator: "_")
    }

    static func didUse(_ key: String) {
        var lastUsed = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        lastUsed[key] = Date.now.timeIntervalSince1970
        let expired = lastUsed.sorted { $0.value > $1.value }.dropFirst(limit).map(\.key)
        for oldKey in expired {
            lastUsed[oldKey] = nil
            for suffix in ["-far", "-near"] {
                TileStore.default.removeRegion(forId: oldKey + suffix) { _ in }
            }
        }
        UserDefaults.standard.set(lastUsed, forKey: defaultsKey)
    }
}

/// Resumes a continuation once, from whichever fires first.
private final class OneShot {
    var continuation: CheckedContinuation<Void, Never>?
    var token: AnyCancelable?

    func fire() {
        continuation?.resume()
        continuation = nil
        token?.cancel()
        token = nil
    }
}

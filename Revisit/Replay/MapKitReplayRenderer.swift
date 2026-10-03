import MapKit

/// Draws replay frames on an `MKMapView` with realistic 3D terrain.
final class MapKitReplayRenderer: NSObject, ReplayRendering, MKMapViewDelegate {
    let mapView = MKMapView()
    var view: UIView { mapView }

    private let overlays = RouteOverlays()
    private let runner = MKPointAnnotation()
    private static let preloadTimeoutPerStop: Duration = .milliseconds(700)

    /// True between MapKit's will-start and did-finish rendering callbacks.
    private var isRendering = false

    #if DEBUG
    private(set) var renderStarts = 0
    private(set) var incompleteRenders = 0
    #endif

    init(content: RouteMapContent) {
        super.init()
        mapView.delegate = self
        // Plain satellite, no labels: labels are re-laid-out on every frame as the camera
        // turns, which costs a lot, and they clutter a flyover anyway.
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        mapView.showsCompass = false
        // The camera is scripted; user gestures would fight it.
        mapView.isUserInteractionEnabled = false
        RouteOverlays.register(on: mapView)
        mapView.register(DotAnnotationView.self, forAnnotationViewWithReuseIdentifier: DotAnnotationView.runnerID)

        overlays.show(content, on: mapView)
        runner.coordinate = CLLocationCoordinate2D(content.start ?? Coordinate(latitude: 0, longitude: 0))
        mapView.addAnnotation(runner)
    }

    func render(camera: CameraState, runner coordinate: Coordinate) {
        mapView.camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(camera.center),
            fromDistance: camera.distance,
            pitch: camera.pitch,
            heading: camera.heading
        )
        runner.coordinate = CLLocationCoordinate2D(coordinate)
    }

    /// Flies the camera through `cameras`, waiting at each until MapKit has finished
    /// drawing, so the tiles along the route are cached before playback.
    func preload(_ cameras: [CameraState], progress: @escaping @MainActor @Sendable (Double) -> Void) async {
        for (index, camera) in cameras.enumerated() {
            guard !Task.isCancelled else { return }
            render(camera: camera, runner: camera.center)
            // Give MapKit a moment to notice it needs new tiles and start rendering.
            try? await Task.sleep(for: .milliseconds(150))
            let deadline = ContinuousClock.now + Self.preloadTimeoutPerStop
            while isRendering, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            progress(Double(index + 1) / Double(cameras.count))
        }
    }

    // MARK: MKMapViewDelegate

    func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        isRendering = true
        #if DEBUG
        renderStarts += 1
        #endif
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        isRendering = false
        #if DEBUG
        if !fullyRendered { incompleteRenders += 1 }
        #endif
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        overlays.renderer(for: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if annotation === runner {
            return mapView.dequeueReusableAnnotationView(withIdentifier: DotAnnotationView.runnerID, for: annotation)
        }
        return RouteOverlays.endpointView(for: annotation, on: mapView)
    }
}

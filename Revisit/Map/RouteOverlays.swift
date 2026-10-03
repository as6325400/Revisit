import MapKit

/// Draws a `RouteMapContent` onto an `MKMapView`: a white casing under a gradient line,
/// plus start/finish markers. Shared by the detail map and the replay.
final class RouteOverlays {
    static let endpointID = "endpoint"

    private var gradientColors: [ObjectIdentifier: [UIColor]] = [:]
    private var casingLines: Set<ObjectIdentifier> = []

    static func register(on mapView: MKMapView) {
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: endpointID)
    }

    /// Replaces any route previously shown on `mapView`.
    func show(_ content: RouteMapContent, on mapView: MKMapView) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations.filter { $0 is EndpointAnnotation })
        gradientColors = [:]
        casingLines = []

        for segment in content.segments where segment.coordinates.count >= 2 {
            let coordinates = segment.coordinates.map(CLLocationCoordinate2D.init)
            let casing = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            casingLines.insert(ObjectIdentifier(casing))
            gradientColors[ObjectIdentifier(line)] = segment.colors.map(UIColor.init)
            mapView.addOverlay(casing, level: .aboveRoads)
            mapView.addOverlay(line, level: .aboveRoads)
        }

        if let start = content.start, let end = content.end {
            if content.isLoop {
                mapView.addAnnotation(EndpointAnnotation(kind: .loop, coordinate: start))
            } else {
                mapView.addAnnotation(EndpointAnnotation(kind: .start, coordinate: start))
                mapView.addAnnotation(EndpointAnnotation(kind: .finish, coordinate: end))
            }
        }
    }

    /// For `MKMapViewDelegate.mapView(_:rendererFor:)`.
    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let id = ObjectIdentifier(polyline)

        let renderer: MKPolylineRenderer
        if casingLines.contains(id) {
            renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.9)
            renderer.lineWidth = 8
        } else {
            let gradient = MKGradientPolylineRenderer(polyline: polyline)
            let colors = gradientColors[id] ?? [Theme.routeUIColor]
            let last = CGFloat(max(colors.count - 1, 1))
            gradient.setColors(colors, locations: colors.indices.map { CGFloat($0) / last })
            gradient.lineWidth = 5
            renderer = gradient
        }
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    /// For `MKMapViewDelegate.mapView(_:viewFor:)`; nil if `annotation` isn't a route endpoint.
    static func endpointView(for annotation: any MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        guard let endpoint = annotation as? EndpointAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: endpointID, for: annotation)
        if let marker = view as? MKMarkerAnnotationView {
            marker.markerTintColor = endpoint.kind == .finish ? .systemRed : .systemGreen
            marker.glyphImage = UIImage(systemName: endpoint.kind == .start ? "flag.fill" : "flag.checkered")
            marker.displayPriority = .required
            marker.titleVisibility = .hidden
        }
        return view
    }
}

final class EndpointAnnotation: NSObject, MKAnnotation {
    enum Kind { case start, finish, loop }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D

    var title: String? {
        switch kind {
        case .start: "起點"
        case .finish: "終點"
        case .loop: "起終點"
        }
    }

    init(kind: Kind, coordinate: Coordinate) {
        self.kind = kind
        self.coordinate = CLLocationCoordinate2D(coordinate)
    }
}

/// A round dot marker: the chart selection on the detail map, the runner in the replay.
final class DotAnnotationView: MKAnnotationView {
    static let selectionID = "selectionDot"
    static let runnerID = "runnerDot"

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let isRunner = reuseIdentifier == Self.runnerID
        let size: CGFloat = isRunner ? 22 : 18
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        backgroundColor = isRunner ? Theme.routeUIColor : .white
        layer.borderWidth = 4
        layer.borderColor = (isRunner ? UIColor.white : UIColor.black.withAlphaComponent(0.8)).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        displayPriority = .required
        zPriority = .max
        collisionMode = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

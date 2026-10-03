import MapKit
import SwiftUI

/// Satellite map with realistic 3D terrain, drawing the route as a gradient line.
/// Uses UIKit's `MKMapView` because SwiftUI's `Map` can't draw per-point gradients.
struct RouteMapView: UIViewRepresentable {
    let content: RouteMapContent
    /// Highlighted point, e.g. while scrubbing a chart.
    var selection: Coordinate?
    var isThreeD = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RouteMKMapView {
        let mapView = RouteMKMapView()
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsScale = true
        RouteOverlays.register(on: mapView)
        mapView.register(DotAnnotationView.self, forAnnotationViewWithReuseIdentifier: DotAnnotationView.selectionID)
        return mapView
    }

    func updateUIView(_ mapView: RouteMKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.content != content {
            let isFirstContent = coordinator.content == nil
            coordinator.content = content
            coordinator.overlays.show(content, on: mapView)
            if isFirstContent {
                mapView.fit(content.segments.flatMap(\.coordinates))
            }
        }
        coordinator.showSelection(selection, on: mapView)
        if coordinator.isThreeD != isThreeD {
            coordinator.isThreeD = isThreeD
            mapView.setPitch(isThreeD ? 60 : 0)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let overlays = RouteOverlays()
        var content: RouteMapContent?
        var isThreeD = false

        private let selectionAnnotation = MKPointAnnotation()
        private var isSelectionShown = false

        func showSelection(_ coordinate: Coordinate?, on mapView: MKMapView) {
            if let coordinate {
                selectionAnnotation.coordinate = CLLocationCoordinate2D(coordinate)
                if !isSelectionShown {
                    mapView.addAnnotation(selectionAnnotation)
                    isSelectionShown = true
                }
            } else if isSelectionShown {
                mapView.removeAnnotation(selectionAnnotation)
                isSelectionShown = false
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            overlays.renderer(for: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation === selectionAnnotation {
                return mapView.dequeueReusableAnnotationView(withIdentifier: DotAnnotationView.selectionID, for: annotation)
            }
            return RouteOverlays.endpointView(for: annotation, on: mapView)
        }
    }
}

/// `MKMapView` that fits the route once it has a real size.
final class RouteMKMapView: MKMapView {
    private var pendingFit: MKMapRect?

    func fit(_ coordinates: [Coordinate]) {
        guard let first = coordinates.first else { return }
        var rect = MKMapRect.null
        for coordinate in coordinates {
            rect = rect.union(MKMapRect(origin: MKMapPoint(CLLocationCoordinate2D(coordinate)), size: MKMapSize(width: 0, height: 0)))
        }
        // Keep very short routes from zooming in absurdly far.
        let minimumSide = MKMapPointsPerMeterAtLatitude(first.latitude) * 300
        rect = rect.insetBy(dx: min(0, (rect.width - minimumSide) / 2), dy: min(0, (rect.height - minimumSide) / 2))
        pendingFit = rect
        setNeedsLayout()
    }

    func setPitch(_ pitch: Double) {
        guard let camera = camera.copy() as? MKMapCamera else { return }
        camera.pitch = pitch
        setCamera(camera, animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let rect = pendingFit, bounds.width > 0, bounds.height > 0 else { return }
        pendingFit = nil
        setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 48, left: 32, bottom: 48, right: 32), animated: false)
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

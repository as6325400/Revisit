import MapKit

nonisolated extension CLLocationCoordinate2D {
    init(_ coordinate: Coordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

nonisolated enum MapGeometry {
    /// A region that shows all `coordinates` with some padding, matching the view's aspect ratio
    /// (width / height) so nothing gets cropped.
    static func region(fitting coordinates: [Coordinate], aspectRatio: Double, padding: Double = 1.35) -> MKCoordinateRegion {
        guard let box = Geo.boundingBox(of: coordinates) else {
            return MKCoordinateRegion()
        }
        let center = box.center
        let cosLatitude = max(cos(center.latitude.radians), 0.01)

        // Work in "latitude degrees" on both axes so the aspect ratio is in real distance.
        var height = max((box.maxLatitude - box.minLatitude) * padding, 0.002)
        var width = max((box.maxLongitude - box.minLongitude) * padding * cosLatitude, 0.002)
        if width / height < aspectRatio {
            width = height * aspectRatio
        } else {
            height = width / aspectRatio
        }

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(center),
            span: MKCoordinateSpan(latitudeDelta: height, longitudeDelta: width / cosLatitude)
        )
    }
}

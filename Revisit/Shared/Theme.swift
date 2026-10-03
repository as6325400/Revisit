import SwiftUI
import UIKit

enum Theme {
    /// The route line color. MapKit and snapshots don't resolve `Color.accentColor`,
    /// so use a concrete color from the asset catalog.
    static let routeUIColor = UIColor(named: "AccentColor") ?? .systemOrange
    static let route = Color(uiColor: routeUIColor)
}

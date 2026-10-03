import Foundation

nonisolated struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t
        )
    }
}

/// Maps metric values onto a cool→hot color ramp. The range is clipped to the
/// 5th–95th percentile so a few GPS or sensor spikes don't wash out the colors.
nonisolated struct ColorScale: Equatable, Sendable {
    var lower: Double
    var upper: Double

    /// Blue (low) → cyan → green → yellow → orange → red (high).
    static let ramp: [RGB] = [
        RGB(red: 0.24, green: 0.46, blue: 0.96),
        RGB(red: 0.10, green: 0.76, blue: 0.86),
        RGB(red: 0.27, green: 0.80, blue: 0.36),
        RGB(red: 0.98, green: 0.84, blue: 0.20),
        RGB(red: 0.99, green: 0.55, blue: 0.15),
        RGB(red: 0.90, green: 0.20, blue: 0.20),
    ]
    static let unknown = RGB(red: 0.62, green: 0.62, blue: 0.62)

    init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }

    /// Nil when there are no known values.
    init?(values: [Double?], lowerPercentile: Double = 0.05, upperPercentile: Double = 0.95) {
        let sorted = values.compactMap { $0 }.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        self.init(
            lower: Self.percentile(sorted, lowerPercentile),
            upper: Self.percentile(sorted, upperPercentile)
        )
    }

    /// Position of `value` within the scale, clamped to 0...1.
    func fraction(of value: Double) -> Double {
        guard upper > lower else { return 0.5 }
        return min(1, max(0, (value - lower) / (upper - lower)))
    }

    func color(for value: Double?) -> RGB {
        guard let value, value.isFinite else { return Self.unknown }
        return Self.color(at: fraction(of: value))
    }

    static func color(at fraction: Double) -> RGB {
        let t = min(1, max(0, fraction))
        let scaled = t * Double(ramp.count - 1)
        let index = min(Int(scaled), ramp.count - 2)
        return RGB.mix(ramp[index], ramp[index + 1], scaled - Double(index))
    }

    /// Linear-interpolated percentile of already-sorted values.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = min(1, max(0, p)) * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = min(lowerIndex + 1, sorted.count - 1)
        let t = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * t
    }
}

import Foundation

nonisolated struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// A location as read from HealthKit, before any cleanup.
nonisolated struct RawLocation: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var timestamp: Date
    /// m/s; negative when unknown.
    var speed: Double
    /// Meters; negative when invalid.
    var horizontalAccuracy: Double

    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

nonisolated struct HeartRateSample: Equatable, Sendable {
    var date: Date
    var bpm: Double
}

/// A cleaned-up route, stored as parallel arrays so it encodes compactly.
nonisolated struct ProcessedTrack: Codable, Equatable, Sendable {
    static let unknownHeartRate: Double = -1

    var latitudes: [Double] = []
    var longitudes: [Double] = []
    /// Smoothed altitude in meters.
    var altitudes: [Double] = []
    /// Seconds since the workout started.
    var times: [Double] = []
    /// Cumulative meters, not counting jumps across pauses.
    var distances: [Double] = []
    /// Smoothed m/s.
    var speeds: [Double] = []
    /// bpm, or `unknownHeartRate`.
    var heartRates: [Double] = []
    /// Index where each continuous (unpaused) segment starts. Always begins with 0 when non-empty.
    var segmentStarts: [Int] = []
    var elevationGain: Double = 0

    var count: Int { latitudes.count }
    var isEmpty: Bool { latitudes.isEmpty }
    var totalDistance: Double { distances.last ?? 0 }
    var hasHeartRate: Bool { heartRates.contains { $0 >= 0 } }

    func coordinate(at index: Int) -> Coordinate {
        Coordinate(latitude: latitudes[index], longitude: longitudes[index])
    }

    var coordinates: [Coordinate] { indices.map(coordinate(at:)) }
    var indices: Range<Int> { 0..<count }

    var segments: [Range<Int>] {
        guard !isEmpty else { return [] }
        let bounds = segmentStarts + [count]
        return zip(bounds, bounds.dropFirst()).map { $0..<$1 }.filter { !$0.isEmpty }
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ProcessedTrack {
        try PropertyListDecoder().decode(ProcessedTrack.self, from: data)
    }
}

nonisolated enum CoordinateCodec {
    static func encode(_ coordinates: [Coordinate]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(coordinates)
    }

    static func decode(_ data: Data) -> [Coordinate] {
        (try? PropertyListDecoder().decode([Coordinate].self, from: data)) ?? []
    }
}

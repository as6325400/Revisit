import Foundation

/// A workout in the shape of a FIT "activity" file, ready to encode.
nonisolated struct FITActivity: Sendable {
    struct Record: Equatable, Sendable {
        var timestamp: Date
        var coordinate: Coordinate?
        /// Meters.
        var altitude: Double?
        var heartRate: Double?
        /// Cumulative meters.
        var distance: Double?
        /// m/s.
        var speed: Double?
    }

    /// One pool length, or a rest between lengths (`isActive == false`).
    struct Length: Equatable, Sendable {
        var start: Date
        var end: Date
        var isActive: Bool
        var strokes: Int?
        var stroke: FITSwimStroke?
    }

    var sport: FITSport
    var start: Date
    var end: Date
    /// Moving time, pauses excluded.
    var timerTime: TimeInterval
    var pauses: [DateInterval] = []
    var records: [Record] = []
    var lengths: [Length] = []
    /// Meters; set for pool swims.
    var poolLength: Double?

    var totalDistance: Double?
    var totalCalories: Double?
    var totalAscent: Double?
    var totalDescent: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
    var totalStrokes: Int?
    var maxSpeed: Double?
    /// Local time offset from UTC in seconds, for the activity's local timestamp.
    var utcOffset: Int = 0
    /// Identifies the file; derived from the HealthKit workout UUID.
    var serialNumber: UInt32 = 1

    // MARK: Encoding

    func encoded() -> Data {
        var writer = FITWriter()
        let hasPosition = records.contains { $0.coordinate != nil }
        let hasAltitude = records.contains { $0.altitude != nil }
        let hasHeartRate = records.contains { $0.heartRate != nil }
        let hasDistance = records.contains { $0.distance != nil }
        let hasSpeed = records.contains { $0.speed != nil }
        let firstPosition = records.first { $0.coordinate != nil }?.coordinate
        let lastPosition = records.last { $0.coordinate != nil }?.coordinate

        writer.write(FITMessage.fileID, [
            FITField(0, .enumeration(4)), // type: activity
            FITField(1, .uint16(255)), // manufacturer: development
            FITField(2, .uint16(1)), // product
            FITField(3, .uint32z(serialNumber)),
            FITField(4, .uint32(Self.fitTime(start))),
            FITField(8, .string("Revisit", size: 16)), // product_name
        ])

        writer.write(FITMessage.event, timerEvent(at: start, type: 0)) // timer start

        // Records, pause/resume events and lengths, in time order.
        var items: [(time: Date, order: Int, write: (inout FITWriter) -> Void)] = []
        for record in Self.oncePerSecond(records) {
            items.append((record.timestamp, 1, { writer in
                var fields = [FITField(253, .uint32(Self.fitTime(record.timestamp)))]
                if hasPosition {
                    fields.append(FITField(0, .sint32(record.coordinate.map { Self.semicircles($0.latitude) })))
                    fields.append(FITField(1, .sint32(record.coordinate.map { Self.semicircles($0.longitude) })))
                }
                if hasAltitude {
                    fields.append(FITField(2, .uint16(record.altitude.flatMap { Self.scaled($0 + 500, by: 5, max: UInt16.max) })))
                    fields.append(FITField(78, .uint32(record.altitude.flatMap { Self.scaled($0 + 500, by: 5, max: UInt32.max) })))
                }
                if hasHeartRate {
                    fields.append(FITField(3, .uint8(record.heartRate.flatMap { Self.scaled($0, by: 1, max: UInt8.max) })))
                }
                if hasDistance {
                    fields.append(FITField(5, .uint32(record.distance.flatMap { Self.scaled($0, by: 100, max: UInt32.max) })))
                }
                if hasSpeed {
                    fields.append(FITField(6, .uint16(record.speed.flatMap { Self.scaled($0, by: 1000, max: UInt16.max) })))
                    fields.append(FITField(73, .uint32(record.speed.flatMap { Self.scaled($0, by: 1000, max: UInt32.max) })))
                }
                writer.write(FITMessage.record, fields)
            }))
        }
        for pause in pauses {
            items.append((pause.start, 0, { $0.write(FITMessage.event, timerEvent(at: pause.start, type: 4)) })) // stop_all
            items.append((pause.end, 2, { $0.write(FITMessage.event, timerEvent(at: pause.end, type: 0)) })) // start
        }
        for (index, length) in lengths.enumerated() {
            items.append((length.end, 3, { $0.write(FITMessage.length, lengthFields(length, index: index)) }))
        }
        for item in items.sorted(by: { ($0.time, $0.order) < ($1.time, $1.order) }) {
            item.write(&writer)
        }

        writer.write(FITMessage.event, timerEvent(at: end, type: 4)) // timer stop_all

        let activeLengths = lengths.filter(\.isActive).count
        let averageSpeed = (totalDistance ?? 0) > 0 && timerTime > 0 ? totalDistance! / timerTime : nil

        var lap: [FITField] = [
            FITField(253, .uint32(Self.fitTime(end))),
            FITField(254, .uint16(0)),
            FITField(0, .enumeration(9)), // event: lap
            FITField(1, .enumeration(1)), // event_type: stop
            FITField(2, .uint32(Self.fitTime(start))),
        ]
        if hasPosition {
            lap += [
                FITField(3, .sint32(firstPosition.map { Self.semicircles($0.latitude) })),
                FITField(4, .sint32(firstPosition.map { Self.semicircles($0.longitude) })),
                FITField(5, .sint32(lastPosition.map { Self.semicircles($0.latitude) })),
                FITField(6, .sint32(lastPosition.map { Self.semicircles($0.longitude) })),
            ]
        }
        lap += summaryFields(elapsed: 7, timer: 8, distance: 9, cycles: 10, calories: 11, averageSpeed: 13, maxSpeed: 14,
                             averageHeartRate: 15, maxHeartRate: 16, ascent: 21, descent: 22, averageSpeedValue: averageSpeed)
        lap += [
            FITField(24, .enumeration(7)), // lap_trigger: session_end
            FITField(25, .enumeration(sport.sport)),
            FITField(39, .enumeration(sport.subSport)),
        ]
        if !lengths.isEmpty {
            lap += [
                FITField(32, .uint16(UInt16(clamping: lengths.count))), // num_lengths
                FITField(35, .uint16(0)), // first_length_index
                FITField(40, .uint16(UInt16(clamping: activeLengths))), // num_active_lengths
            ]
        }
        writer.write(FITMessage.lap, lap)

        var session: [FITField] = [
            FITField(253, .uint32(Self.fitTime(end))),
            FITField(254, .uint16(0)),
            FITField(0, .enumeration(8)), // event: session
            FITField(1, .enumeration(1)), // event_type: stop
            FITField(2, .uint32(Self.fitTime(start))),
        ]
        if hasPosition {
            session += [
                FITField(3, .sint32(firstPosition.map { Self.semicircles($0.latitude) })),
                FITField(4, .sint32(firstPosition.map { Self.semicircles($0.longitude) })),
            ]
        }
        session += [
            FITField(5, .enumeration(sport.sport)),
            FITField(6, .enumeration(sport.subSport)),
        ]
        session += summaryFields(elapsed: 7, timer: 8, distance: 9, cycles: 10, calories: 11, averageSpeed: 14, maxSpeed: 15,
                                 averageHeartRate: 16, maxHeartRate: 17, ascent: 22, descent: 23, averageSpeedValue: averageSpeed)
        session += [
            FITField(25, .uint16(0)), // first_lap_index
            FITField(26, .uint16(1)), // num_laps
            FITField(28, .enumeration(0)), // trigger: activity_end
        ]
        if !lengths.isEmpty || poolLength != nil {
            session += [
                FITField(33, .uint16(UInt16(clamping: lengths.count))), // num_lengths
                FITField(44, .uint16(poolLength.flatMap { Self.scaled($0, by: 100, max: UInt16.max) })), // pool_length
                FITField(46, .enumeration(0)), // pool_length_unit: metric
                FITField(47, .uint16(UInt16(clamping: activeLengths))), // num_active_lengths
            ]
        }
        writer.write(FITMessage.session, session)

        let finish = Self.fitTime(end)
        writer.write(FITMessage.activity, [
            FITField(253, .uint32(finish)),
            FITField(0, .uint32(Self.scaled(timerTime, by: 1000, max: UInt32.max))), // total_timer_time
            FITField(1, .uint16(1)), // num_sessions
            FITField(2, .enumeration(0)), // type: manual
            FITField(3, .enumeration(26)), // event: activity
            FITField(4, .enumeration(1)), // event_type: stop
            FITField(5, .uint32(UInt32(clamping: Int64(finish) + Int64(utcOffset)))), // local_timestamp
        ])
        return writer.data()
    }

    private func timerEvent(at date: Date, type: UInt8) -> [FITField] {
        [
            FITField(253, .uint32(Self.fitTime(date))),
            FITField(0, .enumeration(0)), // event: timer
            FITField(1, .enumeration(type)),
            FITField(4, .uint8(0)), // event_group
        ]
    }

    private func lengthFields(_ length: Length, index: Int) -> [FITField] {
        let duration = length.end.timeIntervalSince(length.start)
        let speed = length.isActive && duration > 0 ? poolLength.map { $0 / duration } : nil
        return [
            FITField(253, .uint32(Self.fitTime(length.end))),
            FITField(254, .uint16(UInt16(clamping: index))),
            FITField(0, .enumeration(28)), // event: length
            FITField(1, .enumeration(1)), // event_type: stop
            FITField(2, .uint32(Self.fitTime(length.start))),
            FITField(3, .uint32(Self.scaled(duration, by: 1000, max: UInt32.max))), // total_elapsed_time
            FITField(4, .uint32(Self.scaled(duration, by: 1000, max: UInt32.max))), // total_timer_time
            FITField(5, .uint16(length.strokes.map { UInt16(clamping: $0) })), // total_strokes
            FITField(6, .uint16(speed.flatMap { Self.scaled($0, by: 1000, max: UInt16.max) })), // avg_speed
            FITField(7, .enumeration(length.stroke?.rawValue)), // swim_stroke
            FITField(12, .enumeration(length.isActive ? 1 : 0)), // length_type
        ]
    }

    /// Totals shared by lap and session; the two messages use different field numbers.
    private func summaryFields(
        elapsed: UInt8, timer: UInt8, distance: UInt8, cycles: UInt8, calories: UInt8,
        averageSpeed: UInt8, maxSpeed: UInt8, averageHeartRate: UInt8, maxHeartRate: UInt8,
        ascent: UInt8, descent: UInt8, averageSpeedValue: Double?
    ) -> [FITField] {
        [
            FITField(elapsed, .uint32(Self.scaled(end.timeIntervalSince(start), by: 1000, max: UInt32.max))),
            FITField(timer, .uint32(Self.scaled(timerTime, by: 1000, max: UInt32.max))),
            FITField(distance, .uint32(totalDistance.flatMap { Self.scaled($0, by: 100, max: UInt32.max) })),
            FITField(cycles, .uint32(totalStrokes.map { UInt32(clamping: $0) })),
            FITField(calories, .uint16(totalCalories.flatMap { Self.scaled($0, by: 1, max: UInt16.max) })),
            FITField(averageSpeed, .uint16(averageSpeedValue.flatMap { Self.scaled($0, by: 1000, max: UInt16.max) })),
            FITField(maxSpeed, .uint16(self.maxSpeed.flatMap { Self.scaled($0, by: 1000, max: UInt16.max) })),
            FITField(averageHeartRate, .uint8(self.averageHeartRate.flatMap { Self.scaled($0, by: 1, max: UInt8.max) })),
            FITField(maxHeartRate, .uint8(self.maxHeartRate.flatMap { Self.scaled($0, by: 1, max: UInt8.max) })),
            FITField(ascent, .uint16(totalAscent.flatMap { Self.scaled($0, by: 1, max: UInt16.max) })),
            FITField(descent, .uint16(totalDescent.flatMap { Self.scaled($0, by: 1, max: UInt16.max) })),
        ]
    }

    // MARK: Units

    /// Seconds since the FIT epoch, 1989-12-31 00:00:00 UTC.
    static func fitTime(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down)) - 631_065_600)
    }

    /// Degrees → semicircles (2^31 per 180°).
    static func semicircles(_ degrees: Double) -> Int32 {
        Int32(clamping: Int64((degrees * 2_147_483_648.0 / 180).rounded()))
    }

    /// `value × scale` rounded, or nil when it doesn't fit (so it's written as "invalid").
    static func scaled<T: FixedWidthInteger & UnsignedInteger>(_ value: Double, by scale: Double, max: T) -> T? {
        let scaledValue = (value * scale).rounded()
        guard scaledValue.isFinite, scaledValue >= 0, scaledValue < Double(max) else { return nil }
        return T(scaledValue)
    }

    /// FIT timestamps have one-second resolution; keep the first record of each second.
    static func oncePerSecond(_ records: [Record]) -> [Record] {
        var result: [Record] = []
        var lastSecond: UInt32?
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            let second = fitTime(record.timestamp)
            if second == lastSecond { continue }
            lastSecond = second
            result.append(record)
        }
        return result
    }
}

nonisolated enum FITMessage {
    static let fileID: UInt16 = 0
    static let session: UInt16 = 18
    static let lap: UInt16 = 19
    static let record: UInt16 = 20
    static let event: UInt16 = 21
    static let activity: UInt16 = 34
    static let length: UInt16 = 101
}

/// FIT `sport` / `sub_sport` pair.
nonisolated struct FITSport: Equatable, Sendable {
    var sport: UInt8
    var subSport: UInt8

    static func of(_ kind: WorkoutKind, indoor: Bool) -> FITSport {
        switch kind {
        case .running: FITSport(sport: 1, subSport: indoor ? 1 : 0) // treadmill
        case .walking: FITSport(sport: 11, subSport: indoor ? 27 : 0) // indoor_walking
        case .hiking: FITSport(sport: 17, subSport: 0)
        case .cycling: FITSport(sport: 2, subSport: indoor ? 6 : 0) // indoor_cycling
        case .openWaterSwimming: FITSport(sport: 5, subSport: 18) // open_water
        case .poolSwimming: FITSport(sport: 5, subSport: 17) // lap_swimming
        }
    }
}

/// FIT `swim_stroke`.
nonisolated enum FITSwimStroke: UInt8, Sendable {
    case freestyle = 0
    case backstroke = 1
    case breaststroke = 2
    case butterfly = 3
    case drill = 4
    case mixed = 5
}

import Foundation
import Testing
@testable import Revisit

/// Minimal FIT reader for checking what `FITWriter` produces.
struct DecodedFIT {
    struct Message {
        var global: UInt16
        var fields: [UInt8: [UInt8]]

        func unsigned(_ number: UInt8) -> UInt64? {
            guard let bytes = fields[number] else { return nil }
            let value = bytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
            let invalid = bytes.count == 8 ? UInt64.max : (UInt64(1) << (8 * UInt64(bytes.count))) - 1
            return value == invalid ? nil : value
        }

        func signed32(_ number: UInt8) -> Int32? {
            guard let raw = unsigned(number) else { return nil }
            let value = Int32(bitPattern: UInt32(truncatingIfNeeded: raw))
            return value == Int32.max ? nil : value
        }
    }

    var headerCRCValid: Bool
    var fileCRCValid: Bool
    var dataSize: Int
    var messages: [Message]

    func all(_ global: UInt16) -> [Message] { messages.filter { $0.global == global } }
    func first(_ global: UInt16) -> Message? { messages.first { $0.global == global } }

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 14, Array(bytes[8..<12]) == Array(".FIT".utf8) else { throw DecodeError.badHeader }
        dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        let headerCRC = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        headerCRCValid = FITCRC.checksum(Data(bytes[0..<12])) == headerCRC
        fileCRCValid = FITCRC.checksum(data) == 0 // CRC over data + its own CRC is zero
        guard bytes.count == 14 + dataSize + 2 else { throw DecodeError.badSize }

        var layouts: [UInt8: (global: UInt16, fields: [(UInt8, Int)])] = [:]
        var messages: [Message] = []
        var index = 14
        while index < 14 + dataSize {
            let header = bytes[index]
            index += 1
            let local = header & 0x0F
            if header & 0x40 != 0 {
                let global = UInt16(bytes[index + 2]) | UInt16(bytes[index + 3]) << 8
                let count = Int(bytes[index + 4])
                index += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    fields.append((bytes[index], Int(bytes[index + 1])))
                    index += 3
                }
                layouts[local] = (global, fields)
            } else {
                guard let layout = layouts[local] else { throw DecodeError.missingDefinition }
                var fields: [UInt8: [UInt8]] = [:]
                for (number, size) in layout.fields {
                    fields[number] = Array(bytes[index..<(index + size)])
                    index += size
                }
                messages.append(Message(global: layout.global, fields: fields))
            }
        }
        self.messages = messages
    }

    enum DecodeError: Error { case badHeader, badSize, missingDefinition }
}

struct FITWriterTests {
    @Test func crcMatchesTheStandardCheckValue() {
        // CRC-16/ARC check value for "123456789".
        #expect(FITCRC.checksum(Data("123456789".utf8)) == 0xBB3D)
    }

    @Test func emptyFileHasValidHeaderAndCRC() throws {
        let decoded = try DecodedFIT(FITWriter().data())
        #expect(decoded.headerCRCValid)
        #expect(decoded.fileCRCValid)
        #expect(decoded.dataSize == 0)
    }

    @Test func reusesDefinitionsForTheSameLayout() throws {
        var writer = FITWriter()
        writer.write(20, [FITField(253, .uint32(1)), FITField(3, .uint8(120))])
        writer.write(20, [FITField(253, .uint32(2)), FITField(3, .uint8(121))])
        writer.write(20, [FITField(253, .uint32(3))]) // different layout → new definition
        let data = writer.data()
        let decoded = try DecodedFIT(data)

        #expect(decoded.messages.count == 3)
        #expect(decoded.messages.map { $0.unsigned(253) } == [1, 2, 3])
        #expect(decoded.messages[1].unsigned(3) == 121)
        #expect(decoded.messages[2].fields[3] == nil)
        // 2 definitions (6 + 3·2 and 6 + 3·1 bytes) + 3 data messages (6 + 6 + 5 bytes).
        #expect(decoded.dataSize == 12 + 9 + 6 + 6 + 5)
    }

    @Test func recyclesLocalTypesBeyondSixteenLayouts() throws {
        var writer = FITWriter()
        for number in 0..<20 {
            writer.write(UInt16(number), [FITField(UInt8(number), .uint16(UInt16(number)))])
        }
        writer.write(0, [FITField(0, .uint16(99))])
        let decoded = try DecodedFIT(writer.data())
        #expect(decoded.messages.count == 21)
        #expect(decoded.messages.last?.global == 0)
        #expect(decoded.messages.last?.unsigned(0) == 99)
    }

    @Test func nilValuesAreWrittenAsInvalid() throws {
        var writer = FITWriter()
        writer.write(20, [FITField(3, .uint8(nil)), FITField(0, .sint32(nil)), FITField(5, .uint32(nil))])
        let message = try #require(try DecodedFIT(writer.data()).messages.first)
        #expect(message.unsigned(3) == nil)
        #expect(message.signed32(0) == nil)
        #expect(message.unsigned(5) == nil)
    }

    @Test func stringsArePaddedAndNullTerminated() throws {
        var writer = FITWriter()
        writer.write(0, [FITField(8, .string("Revisit", size: 10))])
        let message = try #require(try DecodedFIT(writer.data()).messages.first)
        #expect(message.fields[8] == Array("Revisit".utf8) + [0, 0, 0])
    }
}

@MainActor
struct FITActivityTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func unitConversions() {
        #expect(FITActivity.fitTime(Date(timeIntervalSince1970: 631_065_600)) == 0)
        #expect(FITActivity.semicircles(180) == Int32.max)
        #expect(FITActivity.semicircles(-90) == -1_073_741_824)
        #expect(FITActivity.scaled(12.345, by: 1000, max: UInt32.max) == 12_345)
        #expect(FITActivity.scaled(-1, by: 1, max: UInt8.max) == nil)
        #expect(FITActivity.scaled(300, by: 1, max: UInt8.max) == nil)
    }

    @Test func outdoorRunEncodesRecordsLapSessionActivity() throws {
        let locations = TestRoutes.straightLine(seconds: 120, speed: 3, startOffset: start.timeIntervalSince(TestRoutes.start))
        var input = WorkoutExportInput(workoutID: UUID(), kind: .running, isIndoor: false, start: start, end: start + 130, duration: 120)
        input.locations = locations
        input.heartRates = stride(from: 0, through: 120, by: 5).map { HeartRateSample(date: start + TimeInterval($0), bpm: 150) }
        input.pauses = [DateInterval(start: start + 60, end: start + 70)]
        input.activeEnergy = 30
        let decoded = try DecodedFIT(FITActivityBuilder.build(input).encoded())

        #expect(decoded.headerCRCValid && decoded.fileCRCValid)
        let fileID = try #require(decoded.first(FITMessage.fileID))
        #expect(fileID.unsigned(0) == 4)

        let records = decoded.all(FITMessage.record)
        #expect(records.count == 121)
        let first = try #require(records.first)
        #expect(first.unsigned(253) == UInt64(FITActivity.fitTime(start)))
        #expect(first.signed32(0) == FITActivity.semicircles(TestRoutes.origin.latitude))
        #expect(first.unsigned(3) == 150)
        #expect(first.unsigned(2) == UInt64((10.0 + 500) * 5)) // altitude 10 m
        // 360 m, minus the one 3 m step that spans the pause.
        #expect(records.last?.unsigned(5).map { Double($0) / 100 }.map { abs($0 - 357) < 1 } == true)

        // Timer start, pause (stop_all), resume (start), final stop_all.
        let timerEvents = decoded.all(FITMessage.event).compactMap { $0.unsigned(1) }
        #expect(timerEvents == [0, 4, 0, 4])

        let session = try #require(decoded.first(FITMessage.session))
        #expect(session.unsigned(5) == 1) // running
        #expect(session.unsigned(6) == 0) // generic
        #expect(session.unsigned(8) == 120_000) // timer time, ms
        #expect(session.unsigned(7) == 130_000) // elapsed, ms
        #expect(session.unsigned(11) == 30)
        #expect(session.unsigned(16) == 150)
        #expect(decoded.all(FITMessage.lap).count == 1)
        let activity = try #require(decoded.first(FITMessage.activity))
        #expect(activity.unsigned(1) == 1)

        // Messages appear in order: file_id first, activity last.
        #expect(decoded.messages.first?.global == FITMessage.fileID)
        #expect(decoded.messages.last?.global == FITMessage.activity)
    }

    @Test func treadmillRunHasNoPositionFields() throws {
        let sample = SampleRoutes.treadmillRun(start: start)
        var input = WorkoutExportInput(workoutID: UUID(), kind: .running, isIndoor: true, start: sample.start, end: sample.end, duration: sample.end.timeIntervalSince(sample.start))
        input.heartRates = sample.heartRates
        input.distanceSamples = sample.distanceSamples
        input.totalDistance = sample.distance
        let decoded = try DecodedFIT(FITActivityBuilder.build(input).encoded())

        let records = decoded.all(FITMessage.record)
        #expect(records.count > 200)
        #expect(records.allSatisfy { $0.fields[0] == nil && $0.fields[1] == nil })
        #expect(records.allSatisfy { $0.unsigned(5) != nil })
        let lastDistance = Double(records.last?.unsigned(5) ?? 0) / 100
        #expect(abs(lastDistance - sample.distance) < 1)

        let session = try #require(decoded.first(FITMessage.session))
        #expect(session.unsigned(5) == 1)
        #expect(session.unsigned(6) == 1) // treadmill
        #expect(session.unsigned(9) == UInt64((sample.distance * 100).rounded()))
    }

    @Test func poolSwimEncodesLengthsWithRests() throws {
        let sample = SampleRoutes.poolSwim(start: start)
        var input = WorkoutExportInput(workoutID: UUID(), kind: .poolSwimming, isIndoor: false, start: sample.start, end: sample.end, duration: sample.end.timeIntervalSince(sample.start))
        input.heartRates = sample.heartRates
        input.distanceSamples = sample.distanceSamples
        input.strokeSamples = sample.strokeSamples
        input.swimLaps = sample.swimLaps
        input.poolLength = sample.poolLength
        input.totalDistance = sample.distance
        let decoded = try DecodedFIT(FITActivityBuilder.build(input).encoded())

        let lengths = decoded.all(FITMessage.length)
        let active = lengths.filter { $0.unsigned(12) == 1 }
        let idle = lengths.filter { $0.unsigned(12) == 0 }
        #expect(active.count == 40)
        #expect(idle.count == 10) // a 10 s lead-in, then a rest after each of the first 9 sets
        #expect(active.allSatisfy { ($0.unsigned(5) ?? 0) >= 15 })
        #expect(active.filter { $0.unsigned(7) == 2 }.count == 4) // one breaststroke set
        #expect(lengths.map { $0.unsigned(254) } == lengths.indices.map { UInt64($0) })

        let session = try #require(decoded.first(FITMessage.session))
        #expect(session.unsigned(5) == 5) // swimming
        #expect(session.unsigned(6) == 17) // lap_swimming
        #expect(session.unsigned(44) == 2500) // 25 m pool, cm
        #expect(session.unsigned(47) == 40)
        #expect(session.unsigned(9) == 100_000) // 1000 m
        let totalStrokes = sample.strokeSamples.reduce(0) { $0 + $1.value }
        #expect(session.unsigned(10) == UInt64(totalStrokes))

        let lap = try #require(decoded.first(FITMessage.lap))
        #expect(lap.unsigned(32) == UInt64(lengths.count))
        #expect(lap.unsigned(40) == 40)
    }

    @Test func openWaterSwimIsSwimmingOpenWater() throws {
        let input = WorkoutExportInput(workoutID: UUID(), kind: .openWaterSwimming, isIndoor: false, start: start, end: start + 60, duration: 60)
        let decoded = try DecodedFIT(FITActivityBuilder.build(input).encoded())
        let session = try #require(decoded.first(FITMessage.session))
        #expect(session.unsigned(5) == 5)
        #expect(session.unsigned(6) == 18)
    }

    @Test func sportMapping() {
        #expect(FITSport.of(.cycling, indoor: false) == FITSport(sport: 2, subSport: 0))
        #expect(FITSport.of(.cycling, indoor: true) == FITSport(sport: 2, subSport: 6))
        #expect(FITSport.of(.walking, indoor: true) == FITSport(sport: 11, subSport: 27))
        #expect(FITSport.of(.hiking, indoor: false) == FITSport(sport: 17, subSport: 0))
    }

    /// Writes sample files for checking with an independent FIT parser when
    /// `TEST_RUNNER_FIT_OUTPUT_DIR` is passed to `xcodebuild test`.
    @Test func writeSampleFilesForExternalValidation() throws {
        guard let directory = ProcessInfo.processInfo.environment["FIT_OUTPUT_DIR"] else { return }
        for sample in SampleRoutes.all(endingBefore: start) {
            var input = WorkoutExportInput(workoutID: UUID(), kind: sample.kind, isIndoor: sample.isIndoor, start: sample.start, end: sample.end, duration: sample.end.timeIntervalSince(sample.start))
            input.locations = sample.locations
            input.heartRates = sample.heartRates
            input.distanceSamples = sample.distanceSamples
            input.strokeSamples = sample.strokeSamples
            input.swimLaps = sample.swimLaps
            input.poolLength = sample.poolLength
            input.totalDistance = sample.distance
            input.activeEnergy = sample.activeEnergy
            input.elevationAscended = sample.elevationGain
            let name = "\(sample.kind.rawValue)\(sample.isIndoor ? "-indoor" : "").fit"
            try FITActivityBuilder.build(input).encoded().write(to: URL(fileURLWithPath: directory).appending(path: name))
        }
    }
}

struct FITActivityBuilderTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func cumulativeDistanceProratesTheSampleInProgress() {
        let samples = [
            WorkoutExportInput.IntervalSample(start: start, end: start + 10, value: 30),
            WorkoutExportInput.IntervalSample(start: start + 10, end: start + 20, value: 40),
        ]
        let values = FITActivityBuilder.cumulative(samples, at: [start, start + 5, start + 10, start + 15, start + 30])
        #expect(values == [0, 15, 30, 50, 70])
    }

    @Test func gpsDistanceSkipsTheJumpAcrossAPause() {
        let before = TestRoutes.straightLine(seconds: 10, speed: 3)
        let after = TestRoutes.straightLine(seconds: 10, speed: 3, startOffset: 100, from: Geo.offset(TestRoutes.origin, north: 0, east: 500))
        let pause = DateInterval(start: TestRoutes.start + 11, end: TestRoutes.start + 100)
        let distances = FITActivityBuilder.gpsDistances(before + after, pauses: [pause])
        let total = (distances.last ?? nil) ?? 0
        #expect(abs(total - 60) < 1)
    }

    @Test func lengthsIncludeRestsLongEnoughToCount() {
        var input = WorkoutExportInput(workoutID: UUID(), kind: .poolSwimming, isIndoor: false, start: start, end: start + 200, duration: 200)
        input.swimLaps = [
            .init(interval: DateInterval(start: start + 2, duration: 30), stroke: .freestyle), // 2 s lead-in: too short for a rest
            .init(interval: DateInterval(start: start + 33, duration: 30), stroke: .freestyle),
            .init(interval: DateInterval(start: start + 90, duration: 30), stroke: .backstroke), // 27 s rest before
        ]
        let lengths = FITActivityBuilder.makeLengths(input)
        #expect(lengths.map(\.isActive) == [true, true, false, true])
        #expect(lengths[2].start == start + 63)
        #expect(lengths[3].stroke == .backstroke)
    }

    @Test func serialNumberIsNeverZero() {
        #expect(FITActivityBuilder.serialNumber(for: UUID(uuid: (0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12))) == 1)
        #expect(FITActivityBuilder.serialNumber(for: UUID()) != 0)
    }
}

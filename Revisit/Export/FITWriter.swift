import Foundation

/// A value for one field of a FIT message, tagged with its FIT base type.
/// `nil` payloads are written as the base type's "invalid" value, which FIT readers treat as absent.
nonisolated enum FITValue: Equatable, Sendable {
    case enumeration(UInt8?)
    case uint8(UInt8?)
    case uint16(UInt16?)
    case uint32(UInt32?)
    case uint32z(UInt32?)
    case sint32(Int32?)
    /// Null-terminated UTF-8, padded or truncated to `size` bytes.
    case string(String, size: Int)

    var baseType: UInt8 {
        switch self {
        case .enumeration: 0x00
        case .uint8: 0x02
        case .uint16: 0x84
        case .uint32: 0x86
        case .uint32z: 0x8C
        case .sint32: 0x85
        case .string: 0x07
        }
    }

    var size: Int {
        switch self {
        case .enumeration, .uint8: 1
        case .uint16: 2
        case .uint32, .uint32z, .sint32: 4
        case let .string(_, size): size
        }
    }

    func append(to data: inout Data) {
        switch self {
        case let .enumeration(value): data.append(value ?? 0xFF)
        case let .uint8(value): data.append(value ?? 0xFF)
        case let .uint16(value): data.appendLittleEndian(value ?? 0xFFFF)
        case let .uint32(value): data.appendLittleEndian(value ?? 0xFFFF_FFFF)
        case let .uint32z(value): data.appendLittleEndian(value ?? 0)
        case let .sint32(value): data.appendLittleEndian(UInt32(bitPattern: value ?? Int32.max))
        case let .string(text, size):
            var bytes = Array(text.utf8.prefix(size - 1))
            bytes += Array(repeating: 0, count: size - bytes.count)
            data.append(contentsOf: bytes)
        }
    }
}

nonisolated struct FITField: Equatable, Sendable {
    var number: UInt8
    var value: FITValue

    init(_ number: UInt8, _ value: FITValue) {
        self.number = number
        self.value = value
    }
}

/// Writes a FIT file: 14-byte header, definition + data messages, trailing CRC.
/// Definitions are emitted automatically whenever a message's field layout is new,
/// reusing the 16 local message slots.
nonisolated struct FITWriter {
    static let profileVersion: UInt16 = 2100

    private var records = Data()
    private var layouts: [Layout] = []
    private var nextLocalType: UInt8 = 0

    private struct Layout: Equatable {
        var globalMessage: UInt16
        var fields: [(number: UInt8, size: Int, baseType: UInt8)]
        var localType: UInt8

        static func == (lhs: Layout, rhs: Layout) -> Bool {
            lhs.globalMessage == rhs.globalMessage
                && lhs.fields.count == rhs.fields.count
                && zip(lhs.fields, rhs.fields).allSatisfy { $0 == $1 }
        }
    }

    mutating func write(_ globalMessage: UInt16, _ fields: [FITField]) {
        let signature = fields.map { (number: $0.number, size: $0.value.size, baseType: $0.value.baseType) }
        let localType: UInt8
        if let existing = layouts.first(where: { $0.globalMessage == globalMessage && $0.fields.elementsEqual(signature, by: ==) }) {
            localType = existing.localType
        } else {
            localType = nextLocalType
            nextLocalType = (nextLocalType + 1) % 16
            layouts.removeAll { $0.localType == localType }
            layouts.append(Layout(globalMessage: globalMessage, fields: signature, localType: localType))
            writeDefinition(globalMessage, signature, localType: localType)
        }

        records.append(localType)
        for field in fields {
            field.value.append(to: &records)
        }
    }

    private mutating func writeDefinition(_ globalMessage: UInt16, _ fields: [(number: UInt8, size: Int, baseType: UInt8)], localType: UInt8) {
        records.append(0x40 | localType)
        records.append(0) // reserved
        records.append(0) // architecture: little endian
        records.appendLittleEndian(globalMessage)
        records.append(UInt8(fields.count))
        for field in fields {
            records.append(field.number)
            records.append(UInt8(field.size))
            records.append(field.baseType)
        }
    }

    /// The complete file.
    func data() -> Data {
        var header = Data()
        header.append(14) // header size
        header.append(0x20) // protocol version 2.0
        header.appendLittleEndian(Self.profileVersion)
        header.appendLittleEndian(UInt32(records.count))
        header.append(contentsOf: Array(".FIT".utf8))
        header.appendLittleEndian(FITCRC.checksum(header))

        var file = header
        file.append(records)
        file.appendLittleEndian(FITCRC.checksum(file))
        return file
    }
}

/// FIT's CRC-16 (same as CRC-16/ARC).
nonisolated enum FITCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func checksum(_ data: Data, startingWith initial: UInt16 = 0) -> UInt16 {
        var crc = initial
        for byte in data {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}

nonisolated extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

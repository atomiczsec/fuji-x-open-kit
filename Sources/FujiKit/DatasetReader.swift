import Foundation

public struct DatasetReader: Sendable {
    public let data: Data
    public var offset = 0
    public init(_ data: Data) {
        self.data = data
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let value = try data.integer(at: offset, as: type)
        offset += MemoryLayout<T>.size
        return value
    }

    public mutating func string() throws -> String {
        let count = Int(try read(UInt8.self))
        var units: [UInt16] = []
        for index in 0..<count {
            let unit = try read(UInt16.self)
            if index == count - 1 {
                guard unit == 0 else {
                    throw PTPError.malformed("Unterminated PTP string")
                }
            } else {
                units.append(unit)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func array<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> [T] {
        let count = Int(try read(UInt32.self))
        guard count <= (data.count - offset) / MemoryLayout<T>.size else {
            throw PTPError.malformed("Truncated array")
        }
        return try (0..<count).map {
            _ in try read(type)
        }
    }
}

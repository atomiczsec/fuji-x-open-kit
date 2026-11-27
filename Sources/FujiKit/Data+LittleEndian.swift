import Foundation

extension Data {
    public mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) {
            append(contentsOf: $0)
        }
    }

    public func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) throws -> T {
        guard offset >= 0, offset <= count, count - offset >= MemoryLayout<T>.size else {
            throw PTPError.malformed("Truncated integer")
        }
        return (0..<MemoryLayout<T>.size).reduce(T.zero) {
            $0 | T(self[startIndex + offset + $1]) << ($1 * 8)
        }
    }

    public mutating func appendPTPString(_ string: String) {
        let units = Array(string.utf16.prefix(254))
        append(UInt8(units.count + 1))
        for unit in units {
            appendLE(unit)
        }
        appendLE(UInt16(0))
    }
}

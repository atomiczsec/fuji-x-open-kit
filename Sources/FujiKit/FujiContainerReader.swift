import Foundation

public struct FujiContainerReader: Sendable {
    private var buffer = Data()
    public init() {
    }

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    public mutating func next() throws -> FujiContainer? {
        guard buffer.count >= 4 else {
            return nil
        }
        let size = Int(try buffer.integer(at: 0, as: UInt32.self))
        guard size >= 12, size <= 256 * 1024 * 1024 else {
            throw PTPError.malformed("Invalid Fuji container length")
        }
        guard buffer.count >= size else {
            return nil
        }
        guard let kind = FujiContainer.Kind(rawValue: try buffer.integer(at: 4)) else {
            throw PTPError.malformed("Invalid Fuji container kind")
        }
        let result = FujiContainer(
            kind, code: try buffer.integer(at: 6), transaction: try buffer.integer(at: 8),
            payload: Data(buffer.dropFirst(12).prefix(size - 12)))
        buffer = Data(buffer.dropFirst(size))
        return result
    }
}

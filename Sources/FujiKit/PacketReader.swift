import Foundation

public struct PacketReader: Sendable {
    private var buffer = Data()
    public let maximumLength: Int
    public init(maximumLength: Int = 16 * 1024 * 1024) {
        self.maximumLength = maximumLength
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> Packet? {
        guard buffer.count >= 4 else {
            return nil
        }
        let size = Int(try buffer.integer(at: 0, as: UInt32.self))
        guard size >= 8, size <= maximumLength else {
            throw PTPError.malformed("Invalid packet length")
        }
        guard buffer.count >= size else {
            return nil
        }
        guard let type = PacketType(rawValue: try buffer.integer(at: 4)) else {
            throw PTPError.malformed("Unknown packet type")
        }
        let packet = Packet(type, payload: Data(buffer.dropFirst(8).prefix(size - 8)))
        buffer = Data(buffer.dropFirst(size))
        return packet
    }
}

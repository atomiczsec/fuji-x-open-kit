import Foundation

public struct Packet: Equatable, Sendable {
    public let type: PacketType
    public let payload: Data
    public init(_ type: PacketType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var bytes = Data()
        bytes.appendLE(UInt32(payload.count + 8))
        bytes.appendLE(type.rawValue)
        bytes.append(payload)
        return bytes
    }
}

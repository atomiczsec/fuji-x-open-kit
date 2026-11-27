import Foundation

public actor WireConnection {
    public let transport: any PTPIPTransport
    public private(set) var bytesIn: UInt64 = 0
    public private(set) var bytesOut: UInt64 = 0
    public init(_ transport: any PTPIPTransport) {
        self.transport = transport
    }

    public func send(_ bytes: Data) async throws {
        try await transport.send(bytes)
        bytesOut += UInt64(bytes.count)
    }

    public func read(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try await transport.receive(maximum: count - data.count)
            guard !chunk.isEmpty, chunk.count <= count - data.count else {
                throw PTPError.disconnected
            }
            bytesIn += UInt64(chunk.count)
            data.append(chunk)
        }
        return data
    }

    public func packet() async throws -> Packet {
        let length = Int(try await read(4).integer(at: 0, as: UInt32.self))
        guard length >= 8, length <= 1024 * 1024 else {
            throw PTPError.malformed("Invalid init length")
        }
        let rest = try await read(length - 4)
        guard let type = PacketType(rawValue: try rest.integer(at: 0)) else {
            throw PTPError.malformed("Invalid init type")
        }
        return Packet(type, payload: Data(rest.dropFirst(4)))
    }

    public func header() async throws -> (
        length: Int, kind: FujiContainer.Kind, code: UInt16, transaction: UInt32
    ) {
        let data = try await read(12)
        let length = Int(try data.integer(at: 0, as: UInt32.self))
        guard length >= 12, let kind = FujiContainer.Kind(rawValue: try data.integer(at: 4)) else {
            throw PTPError.malformed("Invalid container header")
        }
        return (length - 12, kind, try data.integer(at: 6), try data.integer(at: 8))
    }

    public func container() async throws -> FujiContainer {
        let header = try await header()
        guard header.length <= 16 * 1024 * 1024 else {
            throw PTPError.malformed("Container too large")
        }
        return FujiContainer(
            header.kind, code: header.code, transaction: header.transaction,
            payload: try await read(header.length))
    }

    public func close() async {
        await transport.close()
    }
}

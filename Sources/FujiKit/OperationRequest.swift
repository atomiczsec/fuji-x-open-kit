import Foundation

public struct OperationRequest: Equatable, Sendable {
    public let phase: DataPhase
    public let code: UInt16
    public let transaction: UInt32
    public let parameters: [UInt32]
    public init(phase: DataPhase, code: UInt16, transaction: UInt32, parameters: [UInt32] = [])
        throws
    {
        guard parameters.count <= 5 else {
            throw PTPError.malformed("Too many operation parameters")
        }
        self.phase = phase
        self.code = code
        self.transaction = transaction
        self.parameters = parameters
    }

    public init(packet: Packet) throws {
        guard packet.type == .operationRequest, packet.payload.count >= 10,
            let phase = DataPhase(rawValue: try packet.payload.integer(at: 0))
        else {
            throw PTPError.malformed("Invalid operation request")
        }
        let count = packet.payload.count - 10
        guard count % 4 == 0, count <= 20 else {
            throw PTPError.malformed("Invalid operation parameters")
        }
        try self.init(
            phase: phase, code: packet.payload.integer(at: 4),
            transaction: packet.payload.integer(at: 6),
            parameters: stride(from: 10, to: packet.payload.count, by: 4).map {
                try packet.payload.integer(at: $0)
            })
    }

    public var packet: Packet {
        var data = Data()
        data.appendLE(phase.rawValue)
        data.appendLE(code)
        data.appendLE(transaction)
        for value in parameters {
            data.appendLE(value)
        }
        return Packet(.operationRequest, payload: data)
    }
}

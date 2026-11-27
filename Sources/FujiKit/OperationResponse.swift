import Foundation

public struct OperationResponse: Equatable, Sendable {
    public let code: UInt16
    public let transaction: UInt32
    public let parameters: [UInt32]
    public init(code: UInt16, transaction: UInt32, parameters: [UInt32] = []) throws {
        guard parameters.count <= 5 else {
            throw PTPError.malformed("Too many response parameters")
        }
        self.code = code
        self.transaction = transaction
        self.parameters = parameters
    }

    public init(packet: Packet) throws {
        let count = packet.payload.count - 6
        guard packet.type == .operationResponse, count >= 0, count <= 20, count % 4 == 0 else {
            throw PTPError.malformed("Invalid operation response")
        }
        try self.init(
            code: packet.payload.integer(at: 0), transaction: packet.payload.integer(at: 2),
            parameters: stride(from: 6, to: packet.payload.count, by: 4).map {
                try packet.payload.integer(at: $0)
            })
    }

    public var packet: Packet {
        var data = Data()
        data.appendLE(code)
        data.appendLE(transaction)
        for value in parameters {
            data.appendLE(value)
        }
        return Packet(.operationResponse, payload: data)
    }
}

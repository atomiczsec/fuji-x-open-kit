import Foundation

public struct FujiContainer: Equatable, Sendable {
    public enum Kind: UInt16, Sendable {
        case command = 1
        case data = 2
        case response = 3
        case event = 4
    }

    public let kind: Kind
    public let code: UInt16
    public let transaction: UInt32
    public let payload: Data
    public init(_ kind: Kind, code: UInt16, transaction: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.code = code
        self.transaction = transaction
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendLE(UInt32(12 + payload.count))
        data.appendLE(kind.rawValue)
        data.appendLE(code)
        data.appendLE(transaction)
        data.append(payload)
        return data
    }
}

import Foundation

extension Packet {
    public static func initEventRequest(connectionNumber: UInt32) -> Packet {
        var data = Data()
        data.appendLE(connectionNumber)
        return Packet(.initEventRequest, payload: data)
    }

    public static func initFailure(reason: UInt32) -> Packet {
        var data = Data()
        data.appendLE(reason)
        return Packet(.initFail, payload: data)
    }

    public static func startData(transaction: UInt32, length: UInt64) -> Packet {
        var data = Data()
        data.appendLE(transaction)
        data.appendLE(length)
        return Packet(.startData, payload: data)
    }

    public static func data(transaction: UInt32, bytes: Data, final: Bool) -> Packet {
        var data = Data()
        data.appendLE(transaction)
        data.append(bytes)
        return Packet(final ? .endData : .data, payload: data)
    }

    public static func event(code: UInt16, transaction: UInt32, parameters: [UInt32] = []) throws
        -> Packet
    {
        guard parameters.count <= 3 else {
            throw PTPError.malformed("Too many event parameters")
        }
        var data = Data()
        data.appendLE(code)
        data.appendLE(transaction)
        for parameter in parameters {
            data.appendLE(parameter)
        }
        return Packet(.event, payload: data)
    }
}

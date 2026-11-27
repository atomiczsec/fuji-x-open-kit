import Foundation

public enum FujiWire {
    public static let commandPort: UInt16 = 55740
    public static let eventPort: UInt16 = 55741
    public static let liveViewPort: UInt16 = 55742

    public static let protocolVersion: UInt32 = 0x8f53_e4f2

    public static let initializationGUIDWords: [UInt32] = [
        0x5d48_a5ad, 0x0b7f_b287, 0xd0de_d5d3, 0,
    ]
    public static let initializationPayloadSize = 74
    public static let friendlyNameMaximumCodeUnits = 26
    public static let cameraConnectRemoteVersion: UInt32 = 0x2000c

    public static let postInitializationDelayNanoseconds: UInt64 = 50_000_000
    public static func initialization(name: String) -> Packet {
        var data = Data()
        data.appendLE(protocolVersion)
        for word in initializationGUIDWords {
            data.appendLE(word)
        }
        for unit in name.utf16.prefix(friendlyNameMaximumCodeUnits) {
            data.appendLE(unit)
        }
        data.append(Data(repeating: 0, count: initializationPayloadSize - data.count))
        return Packet(.initCommandRequest, payload: data)
    }
}

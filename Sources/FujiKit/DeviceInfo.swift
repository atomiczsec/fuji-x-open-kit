import Foundation

public struct DeviceInfo: Sendable {
    public let manufacturer: String
    public let model: String
    public let version: String
    public let serialNumber: String
    init(model: String) {
        self.model = model
        manufacturer = ""
        version = ""
        serialNumber = ""
    }

    public init(data: Data) throws {
        var reader = DatasetReader(data)
        _ = try reader.read(UInt16.self)
        _ = try reader.read(UInt32.self)
        _ = try reader.read(UInt16.self)
        _ = try reader.string()
        _ = try reader.read(UInt16.self)
        for _ in 0..<5 {
            _ = try reader.array(UInt16.self)
        }
        manufacturer = try reader.string()
        model = try reader.string()
        version = try reader.string()
        serialNumber = try reader.string()
    }
}

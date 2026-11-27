import Foundation

public struct ObjectInfo: Sendable {
    public let storageID: UInt32
    public let size: UInt32
    public let format: UInt16
    public let filename: String
    public init(data: Data) throws {
        var reader = DatasetReader(data)
        storageID = try reader.read()
        format = try reader.read()
        _ = try reader.read(UInt16.self)
        size = try reader.read()
        guard data.count >= 52 else {
            throw PTPError.malformed("Truncated object info")
        }
        reader.offset = 52
        filename = try reader.string()
    }
}

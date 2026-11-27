import Foundation

public struct StorageInfo: Sendable {
    public let capacity: UInt64
    public let freeSpace: UInt64
    public let description: String
    public let label: String
    public init(data: Data) throws {
        var reader = DatasetReader(data)
        for _ in 0..<3 {
            _ = try reader.read(UInt16.self)
        }
        capacity = try reader.read()
        freeSpace = try reader.read()
        _ = try reader.read(UInt32.self)
        description = try reader.string()
        label = try reader.string()
    }
}

import Foundation

public protocol PTPIPTransport: Sendable {
    func send(_ bytes: Data) async throws
    func receive(maximum: Int) async throws -> Data
    func close() async
}

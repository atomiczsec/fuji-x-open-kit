import Foundation

public struct ConnectionTelemetry: Sendable {
    public enum State: String, Sendable {
        case disconnected
        case connecting
        case initializing
        case ready
        case transferring
        case failed
    }

    public var state: State = .disconnected
    public var lastRoundTripTime: TimeInterval = 0
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public var bytesPerSecond: Double = 0
    public init() {
    }
}

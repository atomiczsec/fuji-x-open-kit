import Foundation

public enum PTPError: Error, Equatable, Sendable {
    case malformed(String)
    case disconnected
    case timeout
    case busy
    case invalidState
    case initializationFailed(UInt32)
    case response(UInt16)
    case socket(Int32)
}

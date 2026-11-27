import Foundation

public enum DataPhase: UInt32, Sendable {

    case none = 1
    case outgoing = 2
    case unknown = 3

    public static let incoming = DataPhase.none
}

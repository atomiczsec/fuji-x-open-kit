import Foundation

public enum ResponseCode: UInt16, Sendable {
    case ok = 0x2001
    case generalError
    case sessionNotOpen
    case invalidTransactionID
    case operationNotSupported
    case invalidObjectHandle = 0x2009
    case devicePropNotSupported = 0x200a
    case noThumbnailPresent = 0x2010
    case sessionAlreadyOpen = 0x201e
}

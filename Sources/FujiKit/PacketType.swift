import Foundation

public enum PacketType: UInt32, CaseIterable, Sendable {
    case initCommandRequest = 1
    case initCommandAck
    case initEventRequest
    case initEventAck
    case initFail
    case operationRequest
    case operationResponse
    case event
    case startData
    case data
    case cancel
    case endData
    case probeRequest
    case probeResponse
}

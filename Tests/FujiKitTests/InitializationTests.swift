import Foundation
import XCTest
@testable import FujiKit

final class InitializationTests: XCTestCase {
    func testRefreshedStateControlsVersionWrite() async throws {
        for state in [FujiCameraState.multipleTransfer, .pcAutoSave, .fullAccess] {
            let (client, server) = InMemoryTransport.pair()
            let camera = Task {
                try await self.serveInitialization(server, refreshedState: state)
            }
            let session = CameraSession(transport: client)
            try await session.connect()
            try await session.close()
            let writes = try await camera.value
            let expected: [UInt32]
            switch state {
            case .multipleTransfer:
                expected = [UInt32(FujiPropertyCode.clientState.rawValue)]
            case .pcAutoSave:
                expected = [UInt32(FujiPropertyCode.clientState.rawValue), UInt32(FujiPropertyCode.autoSaveVersion.rawValue)]
            default:
                expected = [UInt32(FujiPropertyCode.clientState.rawValue), UInt32(FujiPropertyCode.getObjectVersion.rawValue)]
            }
            XCTAssertEqual(writes, expected)
        }
    }

    func testApprovalDeadlineIncludesSlowResponses() async throws {
        let (client, server) = InMemoryTransport.pair()
        let camera = Task {
            try await self.serveInitialization(server, approvalDelay: .milliseconds(60))
        }
        let session = CameraSession(transport: client, approvalTimeout: .milliseconds(30))
        do {
            try await session.connect()
            XCTFail("Accepted approval after deadline")
        } catch {
            XCTAssertEqual(error as? PTPError, .timeout)
        }
        _ = try await camera.value
    }

    private func serveInitialization(
        _ transport: any PTPIPTransport, approvalDelay: Duration = .zero,
        refreshedState: FujiCameraState = .fullAccess
    ) async throws -> [UInt32] {
        let wire = WireConnection(transport)
        _ = try await wire.packet()
        try await wire.send(Packet(.initCommandAck).encoded())
        var eventReads = 0
        var writes: [UInt32] = []
        do {
            while true {
                let command = try await wire.container()
                let parameter = (try? command.payload.integer(at: 0, as: UInt32.self)) ?? 0
                var response = ResponseCode.ok.rawValue
                var payload: Data?
                if command.code == OperationCode.getDevicePropValue.rawValue {
                    if parameter == UInt32(FujiPropertyCode.eventsList.rawValue) {
                        eventReads += 1
                        if eventReads == 1 {
                            try await Task.sleep(for: approvalDelay)
                        }
                        var events = Data()
                        events.appendLE(UInt16(1))
                        events.appendLE(FujiPropertyCode.cameraState.rawValue)
                        events.appendLE(eventReads == 1 ? FujiCameraState.fullAccess.rawValue : refreshedState.rawValue)
                        payload = events
                    } else if parameter == UInt32(FujiPropertyCode.remoteVersion.rawValue) {
                        response = ResponseCode.devicePropNotSupported.rawValue
                    } else {
                        var version = Data()
                        version.appendLE(UInt32(1))
                        payload = version
                    }
                } else if command.code == OperationCode.setDevicePropValue.rawValue {
                    writes.append(parameter)
                    let data = try await wire.container()
                    XCTAssertEqual(command.kind, .command)
                    XCTAssertEqual(data.kind, .data)
                }
                if let payload {
                    try await wire.send(FujiContainer(.data, code: command.code,
                        transaction: command.transaction, payload: payload).encoded())
                }
                try await wire.send(FujiContainer(.response, code: response,
                    transaction: command.transaction).encoded())
                if command.code == OperationCode.closeSession.rawValue {
                    break
                }
            }
        } catch PTPError.disconnected {
        }
        await wire.close()
        return writes
    }
}

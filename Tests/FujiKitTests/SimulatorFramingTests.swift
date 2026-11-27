import Foundation
import FujiCameraSimulator
import XCTest
@testable import FujiKit

final class SimulatorFramingTests: XCTestCase {
    func testSimulatorRejectsDataAsCommand() async throws {
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task {
            try await FujiCameraSimulator().serve(transport: server)
        }
        let wire = WireConnection(client)
        try await wire.send(FujiWire.initialization(name: "test").encoded())
        _ = try await wire.packet()
        try await wire.send(FujiContainer(
            .data, code: OperationCode.setDevicePropValue.rawValue, transaction: 1
        ).encoded())
        do {
            try await simulator.value
            XCTFail("Accepted data as a command")
        } catch {
            XCTAssertEqual(error as? PTPError, .malformed("Expected command container"))
        }
        await wire.close()
    }
}

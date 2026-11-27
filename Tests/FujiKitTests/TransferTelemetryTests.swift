import Foundation
import FujiCameraSimulator
import FujiKit
import XCTest

final class TransferTelemetryTests: XCTestCase {
    func testXAppFinalRateSurvivesPropertyWrites() async throws {
        let values = try await transfer(payload: Data(repeating: 1, count: 0x100000 + 31), handle: 2, xApp: true)
        let final = try XCTUnwrap(values.last { $0.state == .ready })
        XCTAssertGreaterThan(final.bytesPerSecond, 0)
        XCTAssertEqual(final.bytesPerSecond, values.last { $0.state == .transferring }?.bytesPerSecond)
    }

    func testXAppEmptyTransferRateIsZero() async throws {
        let values = try await transfer(payload: Data(), handle: 2, xApp: true)
        XCTAssertTrue(values.allSatisfy { $0.bytesPerSecond == 0 })
    }

    func testXAppRejectedTransferRateIsZero() async throws {
        let values = try await transfer(payload: Data([1]), handle: 999, xApp: true)
        XCTAssertTrue(values.allSatisfy { $0.bytesPerSecond == 0 })
    }

    func testLiveTransferRateAndFinalRate() async throws {
        let values = try await transfer(payload: FujiCameraSimulator.objects[2]!, handle: 2)
        let samples = values.filter { $0.state == .transferring }
        XCTAssertEqual(samples.first?.bytesPerSecond, 0)
        let liveSamples = samples.filter { $0.bytesPerSecond > 0 }
        XCTAssertGreaterThanOrEqual(liveSamples.count, 3)
        XCTAssertGreaterThan(Set(liveSamples.map(\.bytesPerSecond)).count, 1)
        let final = try XCTUnwrap(values.last { $0.state == .ready })
        XCTAssertGreaterThan(final.bytesPerSecond, 0)
        XCTAssertEqual(
            final.bytesPerSecond * final.lastRoundTripTime,
            Double(FujiCameraSimulator.objects[2]!.count),
            accuracy: 0.001
        )
    }

    func testEmptyTransferRateIsZero() async throws {
        let values = try await transfer(payload: Data(), handle: 2)
        XCTAssertTrue(
            values.filter { $0.state == .transferring }.allSatisfy { $0.bytesPerSecond == 0 })
        XCTAssertEqual(values.last { $0.state == .ready }?.bytesPerSecond, 0)
    }

    func testRejectedTransferDoesNotReusePreviousRate() async throws {
        let values = try await transfer(payload: Data([1]), handle: 999)
        XCTAssertTrue(
            values.filter { $0.state == .transferring }.allSatisfy { $0.bytesPerSecond == 0 })
        XCTAssertEqual(values.last { $0.state == .ready }?.bytesPerSecond, 0)
    }

    private func transfer(payload: Data, handle: UInt32, xApp: Bool = false) async throws -> [ConnectionTelemetry] {
        let (client, server) = InMemoryTransport.pair()
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = xApp
        configuration.objects[2] = payload
        let simulator = Task {
            try await FujiCameraSimulator(configuration: configuration).serve(transport: server)
        }
        let session = CameraSession(transport: client)
        try await session.connect(mode: xApp ? .bluetoothXApp : .wirelessCommunication)
        _ = try await session.getDeviceInfo()
        let stream = await session.telemetry()
        let recorder = Task {
            var values: [ConnectionTelemetry] = []
            for await value in stream {
                values.append(value)
            }
            return values
        }
        do {
            try await session.getObject(handle) { _ in
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(handle, 2)
        } catch {
            XCTAssertEqual(handle, 999)
            XCTAssertEqual(error as? PTPError, .response(ResponseCode.invalidObjectHandle.rawValue))
        }
        try await session.close()
        try await simulator.value
        let values = await recorder.value
        let transferStart = try XCTUnwrap(values.firstIndex { $0.state == .transferring })
        let transferEnd = try XCTUnwrap(values[transferStart...].firstIndex { $0.state == .ready })
        return Array(values[transferStart...transferEnd])
    }
}

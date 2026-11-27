import Foundation
import XCTest
@testable import FujiKit
import FujiCameraSimulator

final class XAppSessionTests: XCTestCase {
    private enum SinkFailure: Error, Equatable { case rejected }

    func testXAppSinkFailureClosesSession() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect(mode: .bluetoothXApp)
        do {
            try await session.getObject(2) { _ in throw SinkFailure.rejected }
            XCTFail("Accepted failing sink")
        } catch {
            XCTAssertEqual(error as? SinkFailure, .rejected)
        }
        do {
            _ = try await session.getObjectInfo(2)
            XCTFail("Reused interrupted data phase")
        } catch {
            XCTAssertEqual(error as? PTPError, .invalidState)
        }
        try await simulator.value
    }

    func testGalleryRefreshSeesAddedRemovedAndEmptyObjects() async throws {
        let gallery = FujiCameraSimulator.Gallery()
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        configuration.gallery = gallery
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect(mode: .bluetoothXApp)
        await gallery.setObject(Data([3]), for: 3)
        let first = try await session.getObjectHandles()
        XCTAssertEqual(first, [1, 2])
        await gallery.setObject(nil, for: 1)
        let second = try await session.getObjectHandles()
        XCTAssertEqual(second, [2, 3])
        await gallery.setObject(nil, for: 2)
        await gallery.setObject(nil, for: 3)
        let third = try await session.getObjectHandles()
        XCTAssertTrue(third.isEmpty)
        try await session.close()
        try await simulator.value
    }

    func testXAppInitialization() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect(mode: .bluetoothXApp)
        let handles = try await session.getObjectHandles()
        XCTAssertEqual(handles, [1, 2])
        try await session.close()
        try await simulator.value
    }

    func testOldRemoteVersionFallsBackToLegacy() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        configuration.remoteVersion = 0x20006
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect(mode: .bluetoothXApp)
        let handles = try await session.getObjectHandles()
        XCTAssertEqual(handles, [1, 2])
        let collector = Collector()
        try await session.getObject(2) { await collector.append($0) }
        let data = await collector.data()
        XCTAssertEqual(data, configuration.objects[2])
        try await session.close()
        try await simulator.value
    }

    func testXAppListAndChunkedDownloadOverTCP() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        configuration.objects = [42: Data(repeating: 0xAB, count: 2 * 0x100000 + 31)]
        configuration.filenames = [42: "DSCF0042.RAF"]
        let listener = try SocketListener(port: 0)
        let simulator = Task {
            try await FujiCameraSimulator(configuration: configuration).serve(transport: listener.accept())
        }
        let session = try await CameraSession.connect(host: "127.0.0.1", port: listener.port, mode: .bluetoothXApp)
        let handles = try await session.getObjectHandles()
        XCTAssertEqual(handles, [42])
        let info = try await session.getObjectInfo(42)
        XCTAssertEqual(info.filename, "DSCF0042.RAF")
        XCTAssertEqual(info.size, UInt32(2 * 0x100000 + 31))
        let collector = Collector()
        try await session.getObject(42) { await collector.append($0) }
        let data = await collector.data()
        XCTAssertEqual(data, configuration.objects[42])
        let count = await collector.count()
        XCTAssertGreaterThanOrEqual(count, 33)
        let chunks = await collector.chunks
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 64 * 1024 })
        try await session.close()
        try await simulator.value
    }

    func testEmptyGalleryAndMissingCard() async throws {
        for cardInserted in [true, false] {
            var configuration = FujiCameraSimulator.Configuration()
            configuration.xApp = true
            configuration.cardInserted = cardInserted
            configuration.objects = [:]
            let (client, server) = InMemoryTransport.pair()
            let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
            let session = CameraSession(transport: client)
            try await session.connect(mode: .bluetoothXApp)
            let handles = try await session.getObjectHandles()
            XCTAssertTrue(handles.isEmpty)
            try await session.close()
            try await simulator.value
        }
    }

    func testXAppDownloadRejectsInvalidHandle() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect(mode: .bluetoothXApp)
        do {
            try await session.getObject(999) { _ in XCTFail("Received invalid object") }
            XCTFail("Accepted invalid handle")
        } catch {
            XCTAssertEqual(error as? PTPError, .response(ResponseCode.invalidObjectHandle.rawValue))
        }
        try await session.close()
        try await simulator.value
    }

    func testSimulatorRejectsLegacyInitializationInXAppMode() async throws {
        var configuration = FujiCameraSimulator.Configuration()
        configuration.xApp = true
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        do {
            try await session.connect()
            XCTFail("Simulator accepted legacy initialization")
        } catch {
            XCTAssertEqual(error as? PTPError, .disconnected)
        }
        do {
            try await simulator.value
            XCTFail("Simulator did not enforce mode 20")
        } catch let error as PTPError {
            guard case .malformed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}

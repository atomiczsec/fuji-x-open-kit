import Foundation
import FujiCameraSimulator
import XCTest

@testable import FujiKit

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

final class FujiKitTests: XCTestCase {
    func testStandardMessages() throws {
        let request = try OperationRequest(
            phase: .none, code: 0x1002, transaction: 0, parameters: [1])
        XCTAssertEqual(
            request.packet.encoded(),
            Data([22, 0, 0, 0, 6, 0, 0, 0, 1, 0, 0, 0, 2, 16, 0, 0, 0, 0, 1, 0, 0, 0]))
        XCTAssertEqual(try OperationRequest(packet: request.packet), request)
        let empty = try OperationRequest(phase: .incoming, code: 0x1001, transaction: 2)
        XCTAssertEqual(try empty.packet.payload.integer(at: 0, as: UInt32.self), 1)
        XCTAssertEqual(DataPhase.outgoing.rawValue, 2)
        XCTAssertEqual(DataPhase.unknown.rawValue, 3)
        XCTAssertEqual(try OperationRequest(packet: empty.packet), empty)
        let response = try OperationResponse(code: 0x2001, transaction: 2, parameters: [7])
        XCTAssertEqual(try OperationResponse(packet: response.packet), response)
        XCTAssertEqual(
            Packet.startData(transaction: 1, length: 4).encoded(),
            Data([20, 0, 0, 0, 9, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(
            Packet.data(transaction: 1, bytes: Data(), final: true).encoded(),
            Data([12, 0, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0]))
        XCTAssertEqual(Packet.initEventRequest(connectionNumber: 1).payload, Data([1, 0, 0, 0]))
        XCTAssertEqual(Packet.initFailure(reason: 3).payload, Data([3, 0, 0, 0]))
        XCTAssertEqual(try Packet.event(code: 0x4002, transaction: 1).type, .event)
        XCTAssertThrowsError(try OperationRequest(packet: Packet(.operationRequest)))
        XCTAssertThrowsError(try OperationResponse(packet: Packet(.operationResponse)))
        XCTAssertThrowsError(
            try OperationRequest(
                phase: .none, code: 0, transaction: 0, parameters: Array(repeating: 0, count: 6)))
        XCTAssertThrowsError(
            try Packet.event(code: 0, transaction: 0, parameters: Array(repeating: 0, count: 4)))
    }

    func testAutoSaveUDPDiscovery() async throws {
        let discovery = try FujiAutoSaveDiscovery(port: 0, timeout: 0.05)
        let greeting = Data("DISCOVER * HTTP/1.1\r\nDSCADDR: 127.0.0.1\r\n".utf8)
        XCTAssertEqual(
            FujiAutoSaveDiscovery.parse(Data("DISCOVER * HTTP/1.1\nDSCADDR: 127.0.0.1\n".utf8)),
            FujiAutoSaveDiscovery.parse(greeting))
        XCTAssertEqual(
            FujiAutoSaveDiscovery.parse(greeting), DiscoveredCamera(host: "127.0.0.1", port: 55740))
        XCTAssertNil(FujiAutoSaveDiscovery.parse(Data()))
        XCTAssertNil(FujiAutoSaveDiscovery.parse(Data("DISCOVER *\r\nDSCADDR: bad".utf8)))
        #if canImport(Glibc)
            let descriptor = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
            defer {
                _ = Glibc.close(descriptor)
            }
        #else
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            defer {
                _ = Darwin.close(descriptor)
            }
        #endif
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = discovery.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = greeting.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, greeting.count)
        let found = await discovery.discover()
        XCTAssertEqual(found, [DiscoveredCamera(host: "127.0.0.1", port: 55740)])
        let empty = try FujiAutoSaveDiscovery(port: 0, timeout: 0.01)
        let missing = await empty.discover()
        XCTAssertTrue(missing.isEmpty)
    }

    func testGoldenPacketsAndPartialReads() throws {
        XCTAssertEqual(Packet(.probeRequest).encoded(), Data([8, 0, 0, 0, 13, 0, 0, 0]))
        let open = FujiContainer(
            .command, code: 0x1002, transaction: 1, payload: Data([1, 0, 0, 0]))
        XCTAssertEqual(open.encoded(), Data([16, 0, 0, 0, 1, 0, 2, 16, 1, 0, 0, 0, 1, 0, 0, 0]))
        let bytes = FujiWire.initialization(name: "A").encoded()
        let prefix: [UInt8] = [
            82, 0, 0, 0, 1, 0, 0, 0, 0xf2, 0xe4, 0x53, 0x8f,
            0xad, 0xa5, 0x48, 0x5d, 0x87, 0xb2, 0x7f, 0x0b,
            0xd3, 0xd5, 0xde, 0xd0, 0, 0, 0, 0, 65, 0,
        ]
        XCTAssertEqual(bytes, Data(prefix + Array(repeating: 0, count: 52)))
        var reader = PacketReader()
        for byte in bytes.dropLast() {
            reader.append(Data([byte]))
            XCTAssertNil(try reader.next())
        }
        reader.append(Data([bytes.last!]))
        XCTAssertEqual(try reader.next(), FujiWire.initialization(name: "A"))
        XCTAssertNil(try reader.next())
        var fuji = FujiContainerReader()
        for byte in open.encoded().dropLast() {
            fuji.append(Data([byte]))
            XCTAssertNil(try fuji.next())
        }
        fuji.append(Data([0]))
        XCTAssertEqual(try fuji.next(), open)
    }

    func testPacketRoundTripsAndCoalescing() throws {
        var reader = PacketReader()
        let packets = PacketType.allCases.map {
            Packet($0, payload: Data([1, 2, 3, 4]))
        }
        reader.append(
            packets.reduce(Data()) {
                $0 + $1.encoded()
            })
        for packet in packets {
            XCTAssertEqual(try reader.next(), packet)
        }
        XCTAssertNil(try reader.next())
    }

    func testBadLengthsAndDatasets() throws {
        for length: UInt32 in [0, 4, 7, UInt32.max] {
            var reader = PacketReader()
            var data = Data()
            data.appendLE(length)
            reader.append(data)
            XCTAssertThrowsError(try reader.next())
        }
        var fuji = FujiContainerReader()
        fuji.append(Data([8, 0, 0, 0]))
        XCTAssertThrowsError(try fuji.next())
        var reader = DatasetReader(Data([0xff, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try reader.array(UInt32.self))
        XCTAssertThrowsError(try DeviceInfo(data: Data()))
        XCTAssertThrowsError(try ObjectInfo(data: Data()))
        var empty = DatasetReader(Data([0, 0, 0, 0]))
        XCTAssertEqual(try empty.array(UInt32.self), [])
        XCTAssertEqual(
            FujiWire.initialization(name: String(repeating: "x", count: 100)).encoded().count, 82)
    }

    private func exercise(_ transport: any PTPIPTransport) async throws {
        let session = CameraSession(transport: transport)
        let stream = await session.telemetry()
        let telemetry = Task {
            () -> [ConnectionTelemetry] in
            var values: [ConnectionTelemetry] = []
            for await value in stream {
                values.append(value)
            }
            return values
        }
        try await session.connect()
        let device = try await session.getDeviceInfo()
        XCTAssertEqual(device.model, "X-SIM")
        let battery = try await session.batteryLevel()
        XCTAssertEqual(battery, 87)
        let ids = try await session.getStorageIDs()
        XCTAssertEqual(ids, [0x10001])
        let storage = try await session.getStorageInfo(ids[0])
        XCTAssertEqual(storage.capacity, 8_000_000_000)
        let handles = try await session.getObjectHandles()
        XCTAssertEqual(handles, [1, 2])
        let info = try await session.getObjectInfo(2)
        XCTAssertEqual(info.filename, "DSCF0002.RAF")
        let collector = Collector()
        try await session.getObject(2) {
            await collector.append($0)
        }
        let data = await collector.data()
        let chunks = await collector.count()
        XCTAssertEqual(data, FujiCameraSimulator.objects[2])
        XCTAssertGreaterThan(chunks, 1)
        do {
            _ = try await session.getObjectInfo(999)
            XCTFail("Expected response error")
        } catch {
            XCTAssertEqual(error as? PTPError, .response(0x2009))
        }
        try await session.close()
        let values = await telemetry.value
        XCTAssertEqual(values.last?.state, .disconnected)
        XCTAssertGreaterThan(values.last?.bytesIn ?? 0, 180_000)
        XCTAssertGreaterThan(values.last?.bytesOut ?? 0, 82)
        XCTAssertTrue(
            values.contains {
                $0.state == .transferring
            })
    }

    func testFullSessionInMemory() async throws {
        let (client, server) = InMemoryTransport.pair()
        let simulator = Task {
            try await FujiCameraSimulator().serve(transport: server)
        }
        try await exercise(client)
        try await simulator.value
    }

    func testFullSessionTCPAndDiscovery() async throws {
        let listener = try SocketListener(port: 0)
        let simulator = Task {
            let probe = try await listener.accept()
            await probe.close()
            let client = try await listener.accept()
            try await FujiCameraSimulator().serve(transport: client)
        }
        let found = await CameraDiscovery(
            hosts: ["127.0.0.1"], includeDefaultGateway: false, port: listener.port, timeout: 0.1
        ).discover()
        XCTAssertEqual(found, [DiscoveredCamera(host: "127.0.0.1", port: listener.port)])
        let client = try await SocketTransport.connect(host: "localhost", port: listener.port)
        try await exercise(client)
        try await simulator.value
    }

    func testClosedPortDiscoveryIsBounded() async throws {
        var port: UInt16 = 0
        do {
            let listener = try SocketListener(port: 0)
            port = listener.port
        }
        let started = Date()
        let found = await CameraDiscovery(
            hosts: ["127.0.0.1"], includeDefaultGateway: false, port: port, timeout: 0.1
        ).discover()
        XCTAssertTrue(found.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let empty = await CameraDiscovery(includeDefaultGateway: false).discover()
        XCTAssertTrue(empty.isEmpty)
    }

    func testInitFail() async throws {
        let (client, server) = InMemoryTransport.pair()
        var configuration = FujiCameraSimulator.Configuration()
        configuration.initializationFailure = 3
        let simulator = Task {
            try await FujiCameraSimulator(configuration: configuration).serve(transport: server)
        }
        let session = CameraSession(transport: client)
        do {
            try await session.connect()
            XCTFail("Expected InitFail")
        } catch {
            XCTAssertEqual(error as? PTPError, .initializationFailed(3))
        }
        try await simulator.value
    }

    func testPTPErrorResponse() async throws {
        let (client, server) = InMemoryTransport.pair()
        var configuration = FujiCameraSimulator.Configuration()
        configuration.rejectedOperation = OperationCode.getDeviceInfo.rawValue
        let simulator = Task {
            try await FujiCameraSimulator(configuration: configuration).serve(transport: server)
        }
        let session = CameraSession(transport: client)
        try await session.connect()
        do {
            _ = try await session.getDeviceInfo()
            XCTFail("Expected PTP error")
        } catch {
            XCTAssertEqual(error as? PTPError, .response(0x2002))
        }
        try await session.close()
        try await simulator.value
    }

    func testTransportEOFAndEmptySend() async throws {
        let (client, server) = InMemoryTransport.pair()
        try await client.send(Data())
        await server.close()
        do {
            _ = try await client.receive(maximum: 8)
            XCTFail("Expected EOF")
        } catch {
            XCTAssertEqual(error as? PTPError, .disconnected)
        }
    }
}

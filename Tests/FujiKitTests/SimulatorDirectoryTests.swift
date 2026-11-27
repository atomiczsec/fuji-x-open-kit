import Foundation
import FujiCameraSimulator
import FujiKit
import XCTest

final class SimulatorDirectoryTests: XCTestCase {
    func testRealFilesMetadataAndBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let raw = Data("raw fixture".utf8)
        try jpeg.write(to: directory.appendingPathComponent("Holiday.jpeg"))
        try raw.write(to: directory.appendingPathComponent("Sample.RAF"))
        try Data([0]).write(to: directory.appendingPathComponent("ignored.txt"))
        let configuration = try FujiCameraSimulator.Configuration(objectsDirectory: directory)
        let (client, server) = InMemoryTransport.pair()
        let task = Task { try await FujiCameraSimulator(configuration: configuration).serve(transport: server) }
        let session = CameraSession(transport: client)
        try await session.connect()
        let handles = try await session.getObjectHandles()
        XCTAssertEqual(handles, [1, 2])
        let info = try await session.getObjectInfo(1)
        XCTAssertEqual(info.filename, "Holiday.jpeg")
        XCTAssertEqual(info.size, UInt32(jpeg.count))
        XCTAssertEqual(info.format, ObjectFormat.jpeg.rawValue)
        let rawInfo = try await session.getObjectInfo(2)
        XCTAssertEqual(rawInfo.filename, "Sample.RAF")
        XCTAssertEqual(rawInfo.format, ObjectFormat.raf.rawValue)
        let collector = Collector()
        try await session.getObject(1) { await collector.append($0) }
        let bytes = await collector.data()
        XCTAssertEqual(bytes, jpeg)
        try await session.close()
        try await task.value
    }

    func testEmptyDirectoryAndMissingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try FujiCameraSimulator.Configuration(objectsDirectory: directory))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try FujiCameraSimulator.Configuration(objectsDirectory: directory).objects.isEmpty)
    }
}

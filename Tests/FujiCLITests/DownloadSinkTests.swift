import Foundation
import XCTest
@testable import fujictl

final class DownloadSinkTests: XCTestCase {
    func testCommitAndAbort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("object.RAF")
        let original = Data([9])
        try original.write(to: output)
        for payload in [Data(), Data([1, 2])] {
            let sink = try DownloadSink(path: output.path)
            try await sink.write(payload)
            XCTAssertEqual(try Data(contentsOf: output), original)
            await sink.abort()
            XCTAssertEqual(try Data(contentsOf: output), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["object.RAF"])
        }
        for payload in [Data(), Data([3, 4])] {
            let sink = try DownloadSink(path: output.path)
            try await sink.write(payload)
            try await sink.commit()
            XCTAssertEqual(try Data(contentsOf: output), payload)
        }
        let missing = directory.appendingPathComponent("missing")
        let sink = try DownloadSink(path: missing.path)
        try await sink.write(Data([1]))
        await sink.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["object.RAF"])
    }
}

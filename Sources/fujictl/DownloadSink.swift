import Foundation
import FujiKit

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

actor DownloadSink {
    private let file: FileHandle
    private let destination: String
    private let temporary: String
    private(set) var count = 0
    init(path: String) throws {
        destination = URL(fileURLWithPath: path).path
        var template = Array((destination + ".XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw PTPError.socket(errno)
        }
        temporary = String(cString: template)
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: temporary)
    }

    func write(_ data: Data) throws {
        try file.write(contentsOf: data)
        count += data.count
    }

    func commit() throws {
        try file.close()
        guard rename(temporary, destination) == 0 else {
            throw PTPError.socket(errno)
        }
    }

    func abort() {
        try? file.close()
        try? FileManager.default.removeItem(atPath: temporary)
    }
}

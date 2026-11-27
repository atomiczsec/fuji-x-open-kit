import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public final class FujiAutoSaveDiscovery: CameraDiscovering, @unchecked Sendable {
    private let descriptor: Int32
    private let timeout: TimeInterval
    public let port: UInt16
    public init(port: UInt16 = 51541, timeout: TimeInterval = 1) throws {
        #if canImport(Glibc)
            let descriptor = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard descriptor >= 0 else {
            throw PTPError.socket(errno)
        }
        self.descriptor = descriptor
        self.timeout = timeout
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            Self.close(descriptor)
            throw PTPError.socket(error)
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        self.port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }

    private static func close(_ descriptor: Int32) {
        #if canImport(Glibc)
            _ = Glibc.close(descriptor)
        #else
            _ = Darwin.close(descriptor)
        #endif
    }

    deinit {
        Self.close(descriptor)
    }

    public static func parse(_ data: Data) -> DiscoveredCamera? {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
            text.hasPrefix("DISCOVER ")
        else {
            return nil
        }
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " :\r\n"))
            .filter { !$0.isEmpty }
        guard let index = tokens.firstIndex(of: "DSCADDR"), index + 1 < tokens.count else {
            return nil
        }
        let host = String(tokens[index + 1])
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            return nil
        }
        return DiscoveredCamera(host: host, port: FujiWire.commandPort)
    }

    public func discover() async -> [DiscoveredCamera] {
        await Task.detached {
            [self] in
            let deadline = Date().addingTimeInterval(max(0, timeout))
            var results: [DiscoveredCamera] = []
            while Date() < deadline {
                var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let remaining = max(0, deadline.timeIntervalSinceNow * 1000)
                guard poll(&item, 1, Int32(min(remaining, Double(Int32.max)))) > 0 else {
                    break
                }
                var data = Data(count: 4097)
                let count = data.withUnsafeMutableBytes {
                    recv(descriptor, $0.baseAddress, $0.count, 0)
                }
                guard count > 0 else {
                    continue
                }
                data.count = count
                if let camera = Self.parse(data), !results.contains(camera) {
                    results.append(camera)
                }
            }
            return results.sorted {
                $0.host < $1.host
            }
        }.value
    }
}

import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public final class SocketTransport: PTPIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    public init(acceptedDescriptor: Int32) {
        descriptor = acceptedDescriptor
        Self.configure(acceptedDescriptor)
    }

    deinit {
        if descriptor >= 0 {
            systemClose(descriptor)
        }
    }

    private static func configure(_ descriptor: Int32) {
        #if !canImport(Glibc)
            var yes: Int32 = 1
            _ = setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func pinned() throws -> Int32 {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard descriptor >= 0 else {
            throw PTPError.disconnected
        }
        let copy = dup(descriptor)
        guard copy >= 0 else {
            throw PTPError.socket(errno)
        }
        return copy
    }

    private func closeNow() {
        lock.lock()
        defer {
            lock.unlock()
        }
        if descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            systemClose(descriptor)
            descriptor = -1
        }
    }

    public func close() async {
        closeNow()
    }

    public static func connect(
        host: String, port: UInt16 = FujiWire.commandPort, timeout: TimeInterval = 2
    ) async throws -> SocketTransport {
        try await Task.detached {

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard
                inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &address.sin_addr) == 1
            else {
                throw PTPError.malformed("Host must be an IPv4 address or localhost")
            }
            let descriptor = socket(AF_INET, streamSocket, 0)
            guard descriptor >= 0 else {
                throw PTPError.socket(errno)
            }
            do {
                let flags = fcntl(descriptor, F_GETFL, 0)
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw PTPError.socket(errno)
                }
                let result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if result != 0 {
                    guard errno == EINPROGRESS else {
                        throw PTPError.socket(errno)
                    }
                    var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(
                        &item, 1, Int32(max(0, min(timeout * 1000, Double(Int32.max)))))
                    guard ready > 0 else {
                        throw ready == 0 ? PTPError.timeout : PTPError.socket(errno)
                    }
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
                        error == 0
                    else {
                        throw PTPError.socket(error == 0 ? errno : error)
                    }
                }
                guard fcntl(descriptor, F_SETFL, flags) == 0 else {
                    throw PTPError.socket(errno)
                }
                return SocketTransport(acceptedDescriptor: descriptor)
            } catch {
                systemClose(descriptor)
                throw error
            }
        }.value
    }

    public func send(_ bytes: Data) async throws {
        let descriptor = try pinned()
        try await Task.detached {
            defer {
                systemClose(descriptor)
            }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < bytes.count {
                    #if canImport(Glibc)
                        let count = Glibc.send(
                            descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset,
                            Int32(MSG_NOSIGNAL))
                    #else
                        let count = Darwin.send(
                            descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset,
                            0)
                    #endif
                    if count < 0 && errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        throw PTPError.socket(errno)
                    }
                    offset += count
                }
            }
        }.value
    }

    public func receive(maximum: Int) async throws -> Data {
        guard maximum > 0 else {
            throw PTPError.malformed("Invalid read size")
        }
        let descriptor = try pinned()
        return try await Task.detached {
            defer {
                systemClose(descriptor)
            }
            var data = Data(count: min(maximum, 64 * 1024))
            let count = data.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard count > 0 else {
                if count == 0 {
                    throw PTPError.disconnected
                }
                throw errno == EAGAIN || errno == EWOULDBLOCK
                    ? PTPError.timeout : PTPError.socket(errno)
            }
            data.count = count
            return data
        }.value
    }
}

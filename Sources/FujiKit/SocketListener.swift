import Foundation
import Dispatch

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public final class SocketListener: @unchecked Sendable {
    private let descriptor: Int32
    public let port: UInt16
    public init(port: UInt16, loopbackOnly: Bool = true) throws {
        let descriptor = socket(AF_INET, streamSocket, 0)
        self.descriptor = descriptor
        guard descriptor >= 0 else {
            throw PTPError.socket(errno)
        }
        var yes: Int32 = 1
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = loopbackOnly ? inet_addr("127.0.0.1") : 0
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(descriptor, 16) == 0 else {
            let error = errno
            systemClose(descriptor)
            throw PTPError.socket(error)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        self.port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        systemClose(descriptor)
    }

    public func accept() async throws -> SocketTransport {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    #if canImport(Glibc)
                        let client = Glibc.accept(descriptor, nil, nil)
                    #else
                        let client = Darwin.accept(descriptor, nil, nil)
                    #endif
                    if client >= 0 {
                        continuation.resume(returning: SocketTransport(acceptedDescriptor: client))
                        return
                    }
                    if errno != EINTR {
                        continuation.resume(throwing: PTPError.socket(errno))
                        return
                    }
                }
            }
        }
    }
}

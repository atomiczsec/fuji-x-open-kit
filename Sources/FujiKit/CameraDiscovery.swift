import Foundation

public struct CameraDiscovery: CameraDiscovering, Sendable {
    public let hosts: [String]
    public let port: UInt16
    public let timeout: TimeInterval
    public init(
        hosts: [String] = [], includeDefaultGateway: Bool = true,
        port: UInt16 = FujiWire.commandPort, timeout: TimeInterval = 0.5
    ) {
        self.hosts = Array(Set((includeDefaultGateway ? ["192.168.0.1"] : []) + hosts)).sorted()
        self.port = port
        self.timeout = timeout
    }

    public func discover() async -> [DiscoveredCamera] {
        await withTaskGroup(of: DiscoveredCamera?.self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        let transport = try await SocketTransport.connect(
                            host: host, port: port, timeout: timeout)
                        await transport.close()
                        return DiscoveredCamera(host: host, port: port)
                    } catch {
                        return nil
                    }
                }
            }
            var cameras: [DiscoveredCamera] = []
            for await camera in group {
                if let camera {
                    cameras.append(camera)
                }
            }
            return cameras.sorted {
                $0.host < $1.host
            }
        }
    }
}

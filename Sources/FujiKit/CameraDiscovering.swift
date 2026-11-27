import Foundation

public protocol CameraDiscovering: Sendable {
    func discover() async -> [DiscoveredCamera]
}

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FujiKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FujiKit", targets: ["FujiKit"]),
        .library(name: "FujiCameraSimulator", targets: ["FujiCameraSimulator"]),
        .executable(name: "fujictl", targets: ["fujictl"]),
    ],
    targets: [
        .target(name: "FujiKit"),
        .target(name: "FujiCameraSimulator", dependencies: ["FujiKit"]),
        .executableTarget(name: "fujictl", dependencies: ["FujiKit", "FujiCameraSimulator"]),
        .testTarget(name: "FujiKitTests", dependencies: ["FujiKit", "FujiCameraSimulator"]),
        .testTarget(name: "FujiCLITests", dependencies: ["fujictl"]),
    ]
)

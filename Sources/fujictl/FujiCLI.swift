import Foundation
import FujiCameraSimulator
import FujiKit

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

@main struct FujiCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let command = arguments.first,
            ["simulate", "probe", "info", "list", "get"].contains(command)
        else {
            print(
                "fujictl simulate|probe|info|list|get <handle> [--host IPv4] [--port N] [--output path] [--objects directory] [--xapp]"
            )
            return
        }
        let host = option("--host") ?? "192.168.0.1"
        guard let port = UInt16(option("--port") ?? "55740") else {
            throw PTPError.malformed("Invalid port")
        }
        if command == "simulate" {
            var configuration: FujiCameraSimulator.Configuration
            if let directory = option("--objects") {
                configuration = try .init(objectsDirectory: URL(fileURLWithPath: directory))
            } else {
                configuration = .init()
            }
            configuration.xApp = arguments.contains("--xapp")
            let simulator = FujiCameraSimulator(configuration: configuration)
            let listener = try SocketListener(port: port)
            print("Fuji simulator listening on 127.0.0.1:\(listener.port)")
            fflush(nil)
            while true {
                let transport = try await listener.accept()
                Task {
                    do {
                        try await simulator.serve(transport: transport)
                    } catch {
                        print("simulator: \(error)")
                    }
                }
            }
        }
        if command == "probe" {
            let cameras = await CameraDiscovery(
                hosts: [host], includeDefaultGateway: false, port: port
            ).discover()
            for camera in cameras {
                print("TCP candidate \(camera.host):\(camera.port) (identity not verified)")
            }
            if cameras.isEmpty {
                print("No cameras found")
            }
            return
        }
        let transport = try await SocketTransport.connect(host: host, port: port)
        let session = CameraSession(transport: transport)
        let stream = await session.telemetry()
        let printer = Task {
            for await telemetry in stream {
                print(
                    String(
                        format: "telemetry %@ in=%llu out=%llu rtt=%.3fs rate=%.0fB/s",
                        telemetry.state.rawValue, telemetry.bytesIn, telemetry.bytesOut,
                        telemetry.lastRoundTripTime,
                        telemetry.bytesPerSecond))
            }
        }
        do {
            try await session.connect(mode: arguments.contains("--xapp") ? .bluetoothXApp : .wirelessCommunication)
            switch command {
            case "info":
                let info = try await session.getDeviceInfo()
                print(
                    "\(TerminalText.escaped(info.manufacturer)) \(TerminalText.escaped(info.model)) firmware=\(TerminalText.escaped(info.version)) serial=\(TerminalText.escaped(info.serialNumber))"
                )
                print("Battery: \(try await session.batteryLevel())%")
                for id in try await session.getStorageIDs() {
                    let storage = try await session.getStorageInfo(id)
                    print(
                        "Storage \(id): \(TerminalText.escaped(storage.description)), \(storage.freeSpace)/\(storage.capacity) bytes free"
                    )
                }
            case "list":
                for handle in try await session.getObjectHandles() {
                    let info = try await session.getObjectInfo(handle)
                    print("\(handle) \(TerminalText.escaped(info.filename)) \(info.size) bytes")
                }
            case "get":
                guard arguments.count > 1, let handle = UInt32(arguments[1]) else {
                    throw PTPError.malformed("Expected numeric handle")
                }
                let path = option("--output") ?? "object-\(handle).bin"
                let sink = try DownloadSink(path: path)
                do {
                    try await session.getObject(handle) {
                        try await sink.write($0)
                    }
                    try await sink.commit()
                } catch {
                    await sink.abort()
                    throw error
                }
                print("Saved \(await sink.count) bytes to \(path)")
            default:
                break
            }
            try await session.close()
            await printer.value
        } catch {
            try? await session.close()
            printer.cancel()
            throw error
        }
    }
}

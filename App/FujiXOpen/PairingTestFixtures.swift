#if PAIRING_TEST_FIXTURES || (DEBUG && targetEnvironment(simulator) && !HOTSPOT_AUTOJOIN)
import Foundation
import FujiKit

#if DEBUG && targetEnvironment(simulator) && !HOTSPOT_AUTOJOIN && !PAIRING_TEST_FIXTURES
import SwiftUI
import UIKit

struct ManualHandoffTestView: View {
    @State private var model: CameraModel
    @State private var bluetooth: FakeCameraBluetooth
    private let churn: Bool

    init() {
        let args = ProcessInfo.processInfo.arguments
        churn = args.contains("-test-nearby-camera-churn")
        let alreadyJoined = args.contains("-test-already-joined")
        let bluetooth = FakeCameraBluetooth()
        if !churn {
            bluetooth.cameras = [BluetoothCamera(id: UUID(), name: "X-T30 III", kind: .basic(token: [1, 2, 3, 4]))]
        }
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIImage(systemName: "mountain.2.fill")?.withTintColor(.white).draw(in: CGRect(x: 80, y: 55, width: 240, height: 190))
        }
        let model = CameraModel(importer: FixturePhotoImporter(), makeSession: { _, _ in FixtureGallery(jpeg: jpeg) })
        model.pairing = CameraPairing(bluetooth: bluetooth, store: MemoryCameraStore(), connectWhenReachable: { [weak model] in
            guard alreadyJoined, let model else { return false }
            return try await model.connectGallery(waitForRoute: true)
        }) { [weak model] in
            try await model?.connectAfterBluetoothHandoff()
        }
        _model = State(initialValue: model)
        _bluetooth = State(initialValue: bluetooth)
    }

    var body: some View {
        ContentView(model: model)
            .task {
                if churn { await advertiseUnderChangingIdentifiersThenStop(bluetooth) }
            }
    }

    private func advertiseUnderChangingIdentifiersThenStop(_ bluetooth: FakeCameraBluetooth) async {
        while !bluetooth.scanning { try? await Task.sleep(for: .milliseconds(100)) }
        var nearby = NearbyCameras(staleAfter: .seconds(3))
        for _ in 0..<8 {
            nearby.saw(BluetoothCamera(id: UUID(), name: "X-T30 III", kind: .secure(serial: [1, 2, 3, 4, 5])))
            bluetooth.cameras = nearby.cameras; bluetooth.onChange?()
            try? await Task.sleep(for: .milliseconds(500))
        }
        while !nearby.cameras.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            nearby.prune()
            bluetooth.cameras = nearby.cameras; bluetooth.onChange?()
        }
    }
}

private struct FixtureGallery: CameraConnection {
    let jpeg: Data
    func connect(name: String, mode: CameraSession.InitializationMode) {}
    func getDeviceInfo(fallbackModel: String?) throws -> DeviceInfo {
        var data = Data(repeating: 0, count: 31)
        for value in ["FUJIFILM", "X-T30 III", "1.0", "SIM0001"] { data.appendPTPString(value) }
        return try DeviceInfo(data: data)
    }
    func reportedBatteryLevel() -> UInt8? { 87 }
    func getStorageIDs() -> [UInt32] { [] }
    func getStorageInfo(_ id: UInt32) throws -> StorageInfo { throw PTPError.disconnected }
    func getObjectHandles(storageID: UInt32) -> [UInt32] { [1, 2] }
    func getObjectInfo(_ handle: UInt32) throws -> ObjectInfo {
        var data = Data()
        data.appendLE(UInt32(1))
        data.appendLE((handle == 1 ? ObjectFormat.jpeg : .raf).rawValue)
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(jpeg.count))
        data.append(Data(repeating: 0, count: 52 - data.count))
        data.appendPTPString(handle == 1 ? "DSCF0001.JPG" : "DSCF0002.RAF")
        return try ObjectInfo(data: data)
    }
    func getThumbnail(_ handle: UInt32) -> Data { jpeg }
    func getObject(_ handle: UInt32, sink: @escaping @Sendable (Data) async throws -> Void) async throws { try await sink(jpeg) }
    func telemetry() -> AsyncStream<ConnectionTelemetry> { AsyncStream { $0.finish() } }
    func close() {}
}

private struct FixturePhotoImporter: PhotoImporting {
    func authorize() {}
    func importPhoto(at url: URL, originalFilename: String) throws { _ = try Data(contentsOf: url) }
}
#endif

actor PairingPeripheral: GATTPeripheral {
    private(set) var writes: [GATTCharacteristic: [UInt8]] = [:]
    let rejectPairing: Bool
    let password: String?
    init(rejectPairing: Bool = false, password: String? = "camera-password") {
        self.rejectPairing = rejectPairing; self.password = password
    }
    func discover() -> [String: Set<String>] {
        let attributes = [FujiBLE.Pairing.token, FujiBLE.Pairing.basicIdentity,
                          FujiBLE.Pairing.status, FujiBLE.Pairing.secureIdentity,
                          FujiBLE.WiFi.ssid, FujiBLE.WiFi.password, FujiBLE.WiFi.trigger,
                          FujiBLE.WiFi.readiness]
        return attributes.reduce(into: [:]) { $0[$1.service, default: []].insert($1.uuid) }
    }
    func read(_ characteristic: GATTCharacteristic) throws -> [UInt8] {
        switch characteristic {
        case FujiBLE.Pairing.status: return [7, 0x96, 0, 0]
        case FujiBLE.Information.name: return Array("X-T30 III".utf8)
        case FujiBLE.WiFi.ssid: return Array("FUJIFILM-X-T30-III".utf8)
        case FujiBLE.WiFi.password:
            if let password { return Array(password.utf8) }
            throw PTPError.disconnected
        case FujiBLE.WiFi.readiness: return [0x01, 0x80]
        default: throw FujiBLEError.missingCharacteristic(characteristic)
        }
    }
    func write(_ value: [UInt8], to characteristic: GATTCharacteristic, withResponse: Bool) throws {
        if rejectPairing { throw PTPError.disconnected }
        writes[characteristic] = value
    }
    func setNotify(_ enabled: Bool, for characteristic: GATTCharacteristic) {}
    func notifications() -> AsyncStream<GATTNotification> { AsyncStream { _ in } }
}

@MainActor final class FakeCameraBluetooth: CameraBluetooth {
    var state: CameraBluetoothState = .poweredOn
    var cameras: [BluetoothCamera] = []
    var onChange: (() -> Void)?
    let peripheral: PairingPeripheral
    private(set) var reconnects: [PairedCamera] = []
    private(set) var scanning = false
    private(set) var disconnects = 0
    init(_ peripheral: PairingPeripheral = PairingPeripheral()) { self.peripheral = peripheral }
    func startScanning() { scanning = true; onChange?() }
    func stopScanning() { scanning = false }
    func connect(_ camera: BluetoothCamera) throws -> any GATTPeripheral {
        guard state == .poweredOn else { throw PTPError.disconnected }
        return peripheral
    }
    func reconnect(_ camera: PairedCamera) throws -> (BluetoothCamera, any GATTPeripheral) {
        reconnects.append(camera)
        return (BluetoothCamera(id: UUID(uuidString: camera.peripheralIdentifier)!,
                                name: camera.name ?? "Camera", kind: camera.kind), peripheral)
    }
    func disconnect() { disconnects += 1; stopScanning() }
}

@MainActor final class MemoryCameraStore: PairedCameraStoring {
    var camera: PairedCamera?
    func load() -> PairedCamera? { camera }
    func save(_ camera: PairedCamera) { self.camera = camera }
    func remove() { camera = nil }
}
#endif

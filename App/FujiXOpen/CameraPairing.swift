import Foundation
#if HOTSPOT_AUTOJOIN
import NetworkExtension
#endif
import Observation
import FujiKit

enum CameraBluetoothState: Equatable {
    case checking, poweredOn, poweredOff, unauthorized, unsupported

    var guidance: String? {
        switch self {
        case .checking: return "Checking Bluetooth…"
        case .poweredOn: return nil
        case .poweredOff: return "Bluetooth is off. Turn it on in Settings → Bluetooth, then try again."
        case .unauthorized: return "Bluetooth access is denied. Allow Fuji X Open in Settings → Privacy & Security → Bluetooth."
        case .unsupported: return "Bluetooth isn’t available on this device. Pair on a physical iPhone or iPad, or use the manual Wi-Fi connection."
        }
    }
}

struct BluetoothCamera: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: FujiBLEKind
}

struct NearbyCameras {
    let staleAfter: Duration
    private(set) var cameras: [BluetoothCamera] = []
    private var lastSeen: [UUID: ContinuousClock.Instant] = [:]

    init(staleAfter: Duration = .seconds(8)) { self.staleAfter = staleAfter }

    @discardableResult
    mutating func saw(_ camera: BluetoothCamera, at now: ContinuousClock.Instant = .now) -> [UUID] {
        let replaced = cameras.filter { $0.id != camera.id && $0.kind == camera.kind }.map(\.id)
        if let index = cameras.firstIndex(where: { $0.id == camera.id || $0.kind == camera.kind }) {
            cameras[index] = camera
        } else {
            cameras.append(camera)
        }
        cameras.removeAll { replaced.contains($0.id) }
        for id in replaced { lastSeen[id] = nil }
        lastSeen[camera.id] = now
        return replaced
    }

    @discardableResult
    mutating func prune(at now: ContinuousClock.Instant = .now) -> [UUID] {
        let stale = cameras.filter { lastSeen[$0.id].map { now - $0 > staleAfter } ?? true }.map(\.id)
        cameras.removeAll { stale.contains($0.id) }
        for id in stale { lastSeen[id] = nil }
        return stale
    }

    mutating func removeAll() { cameras = []; lastSeen = [:] }
}

@MainActor
protocol CameraBluetooth: AnyObject {
    var state: CameraBluetoothState { get }
    var cameras: [BluetoothCamera] { get }
    var onChange: (() -> Void)? { get set }
    func startScanning()
    func stopScanning()
    func connect(_ camera: BluetoothCamera) async throws -> any GATTPeripheral
    func reconnect(_ camera: PairedCamera) async throws -> (BluetoothCamera, any GATTPeripheral)
    func disconnect()
}

protocol CameraWiFiJoining: Sendable {
    func join(_ credentials: WiFiCredentials) async throws
    func removeConfiguration(forSSID ssid: String) async
}

#if HOTSPOT_AUTOJOIN
struct HotspotCameraWiFi: CameraWiFiJoining {
    func removeConfiguration(forSSID ssid: String) async {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    static func configuration(ssid: String, passphrase: String?) -> NEHotspotConfiguration {
        let configuration: NEHotspotConfiguration
        if let password = passphrase {
            configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)

            configuration.hidden = true
        } else {
            configuration = NEHotspotConfiguration(ssid: ssid)
        }
        return configuration
    }

    func join(_ credentials: WiFiCredentials) async throws {
        let configuration = Self.configuration(ssid: credentials.ssid, passphrase: credentials.passphrase)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error = error as NSError?,
                   !(error.domain == NEHotspotConfigurationErrorDomain
                     && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif

@MainActor
protocol PairedCameraStoring {
    func load() -> PairedCamera?
    func save(_ camera: PairedCamera)
    func remove()
}

struct LocalPairedCameraStore: PairedCameraStoring {
    let defaults: UserDefaults
    private let key = "pairedCamera"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> PairedCamera? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PairedCamera.self, from: $0) }
    }
    func save(_ camera: PairedCamera) {
        if let data = try? JSONEncoder().encode(camera) { defaults.set(data, forKey: key) }
    }
    func remove() { defaults.removeObject(forKey: key) }
}

@MainActor @Observable
final class CameraPairing {
    enum Progress: String {
        case pairing = "Pairing…"
        case turningOnWiFi = "Turning on camera Wi-Fi…"
        case joiningWiFi = "Joining Wi-Fi…"
        case connecting = "Connecting…"
        case diagnosing = "Running Bluetooth step…"
    }
    enum DiagnosticStep: String, CaseIterable, Identifiable {
        case discover = "Discover BLE services"
        case pairingKey = "Write advertised pairing key"
        case secureRead = "Read secure pairing status"
        case secureAck = "Acknowledge secure pairing status"
        case identity = "Write device name"
        case subscribe = "Subscribe to AP state"
        case state = "Read AP state"
        case error = "Read AP error detail"
        case ssid = "Read Wi-Fi network name"
        case password = "Read Wi-Fi password"
        case gallery = "Request gallery Wi-Fi (03 00)"
        case remote = "Request remote Wi-Fi (04 00)"

        var id: Self { self }
    }
    private(set) var savedCamera: PairedCamera?
    private(set) var cameras: [BluetoothCamera] = []
    private(set) var bluetoothState: CameraBluetoothState = .checking
    private(set) var progress: Progress?
    private(set) var manualJoin: WiFiCredentials?
    private(set) var hasBluetoothLink = false
    private(set) var diagnosticSSID: String?
    private(set) var diagnosticPassword: String?
    private(set) var lastAPState: String?
    private(set) var lastAPError: String?
    var error: String?
    private var automaticJoinInFlight = false
    var isWorking: Bool { progress != nil || automaticJoinInFlight }
    @ObservationIgnored private let bluetooth: any CameraBluetooth
    @ObservationIgnored private let wifi: (any CameraWiFiJoining)?
    @ObservationIgnored private let store: any PairedCameraStoring
    @ObservationIgnored private let connectWhenReachable: (@MainActor () async throws -> Bool)?
    @ObservationIgnored private let connectCamera: @MainActor () async throws -> Void
    @ObservationIgnored private let trace: CameraConnectionTrace
    @ObservationIgnored private var peripheral: (any GATTPeripheral)?
    @ObservationIgnored private var peripheralKind: FujiBLEKind?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var apReady = false

    init(bluetooth: any CameraBluetooth, wifi: (any CameraWiFiJoining)? = nil,
         store: (any PairedCameraStoring)? = nil,
         trace: CameraConnectionTrace? = nil,
         connectWhenReachable: (@MainActor () async throws -> Bool)? = nil,
         connectCamera: @escaping @MainActor () async throws -> Void) {
        self.bluetooth = bluetooth
#if HOTSPOT_AUTOJOIN
        self.wifi = wifi ?? HotspotCameraWiFi()
#else
        self.wifi = wifi
#endif
        self.store = store ?? LocalPairedCameraStore()
        self.connectWhenReachable = connectWhenReachable
        self.connectCamera = connectCamera
        self.trace = trace ?? CameraConnectionTrace()
        savedCamera = self.store.load()
        bluetoothState = bluetooth.state
        bluetooth.onChange = { [weak self] in self?.updateBluetooth() }
    }

    private func updateBluetooth() {
        bluetoothState = bluetooth.state
        cameras = bluetooth.cameras
    }

    func scan() {
        error = nil
        bluetooth.startScanning()
        updateBluetooth()
    }

    func stopScanning() { bluetooth.stopScanning() }

    func pair(_ camera: BluetoothCamera) async {
        guard !isWorking else { return }
        if hasBluetoothLink { releaseBluetooth() }
        trace.record("Connecting Bluetooth for pairing")
        progress = .pairing; error = nil; manualJoin = nil
        var failed = false
        defer {
            progress = nil
            if !apReady { releaseBluetooth() }
            if failed { bluetooth.startScanning() }
        }
        do {
            let peripheral = try await bluetooth.connect(camera)
            try await pairAndHandoff(camera, peripheral: peripheral)
        } catch { pairingFailed(error); failed = true }
    }

    func connectSaved() async {
        guard !isWorking, let savedCamera else { return }
        if hasBluetoothLink { releaseBluetooth() }
        trace.record("Connecting to saved camera over Bluetooth")
        progress = .pairing; error = nil; manualJoin = nil
        defer {
            progress = nil
            if !apReady { releaseBluetooth() }
        }
        do {
            let (camera, peripheral) = try await bluetooth.reconnect(savedCamera)
            try await pairAndHandoff(camera, peripheral: peripheral)
        } catch { pairingFailed(error) }
    }

    private func pairingFailed(_ failure: Error) {
        recordBluetoothFailure(failure)
        switch progress {
        case .pairing:
            error = "Bluetooth pairing didn’t finish, so the camera’s Wi-Fi hasn’t started. On the camera, return to the shooting display, press DISP/BACK, then choose Bluetooth → PAIRING and try again. Confirm matching codes if shown. If it still fails, use Forget This Device in Settings → Bluetooth if the camera is listed, then use DELETE PAIRING REG. in the camera’s Bluetooth/SMARTPHONE SETTING for this device. \(failure.localizedDescription)"
        case .turningOnWiFi:
            error = "Bluetooth pairing finished, but the camera’s Wi-Fi couldn’t be started. Return to the camera’s shooting display, keep it awake, and try Connect again. \(failure.localizedDescription)"
        default:
            error = "Couldn’t connect to the camera. Keep it awake and check its Wi-Fi. \(failure.localizedDescription)"
        }
    }

    private func pairAndHandoff(_ camera: BluetoothCamera, peripheral: any GATTPeripheral) async throws {
        await trackBluetooth(peripheral, kind: camera.kind)
        let driver = FujiBLEDriver(peripheral: peripheral, trace: trace.reporter("BLE"))
        try await driver.pair(kind: camera.kind, clientName: "Fuji X Open")
        trace.record("BLE registration acknowledged")
        let info = try await driver.cameraInfo()
        var record = PairedCamera(peripheralIdentifier: camera.id.uuidString, kind: camera.kind,
                                  name: info.name ?? camera.name, ssid: savedCamera?.ssid)
        savedCamera = record; store.save(record)
        progress = .turningOnWiFi
        let credentials = try await driver.handoff(function: .imageBrowsing)
        guard !credentials.readinessTimedOut else {
            throw ImportFailure(message: startupTimeoutMessage)
        }
        apReady = hasBluetoothLink
        record.ssid = credentials.ssid
        savedCamera = record; store.save(record)
        guard let wifi else {
            manualJoin = credentials
            trace.record("Waiting for user to join camera Wi-Fi")
            return
        }
        progress = .joiningWiFi
        do { try await wifi.join(credentials) }
        catch {
            manualJoin = credentials
            return
        }
        manualJoin = credentials
        progress = .connecting
        try await connectCamera()
        manualJoin = nil
    }

    private var startupTimeoutMessage: String {
        var message = "The camera did not confirm Wi-Fi startup."
        if let lastAPState { message += " Last AP state: \(lastAPState)." }
        if let lastAPError { message += " Last camera error detail: \(lastAPError)." }
        return message
    }

    func waitForCameraWiFi(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        guard let connectWhenReachable else { return }
        var delay = Duration.seconds(4)
        while manualJoin != nil, error == nil {
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, manualJoin != nil, error == nil else { return }
            guard !isWorking else { continue }
            automaticJoinInFlight = true
            defer {
                automaticJoinInFlight = false
                progress = nil
            }
            do {
                if try await connectWhenReachable() {
                    trace.record("Camera reachable. Gallery connected automatically.")
                    manualJoin = nil
                    return
                }
            } catch {
                if !Task.isCancelled, manualJoin != nil { pairingFailed(error) }
                return
            }
            delay = min(delay + .seconds(4), .seconds(12))
        }
    }

    func continueAfterManualJoin() async {
        guard progress == nil, manualJoin != nil else { return }
        if automaticJoinInFlight {
            progress = .connecting
            return
        }
        trace.record("User tapped I’ve joined; opening the gallery")
        progress = .connecting; error = nil
        defer { progress = nil }
        do {
            try await connectCamera()
            manualJoin = nil
        } catch { pairingFailed(error) }
    }

    func forget() async {
        guard !isWorking else { return }
        releaseBluetooth()
        let ssid = savedCamera?.ssid
        store.remove(); savedCamera = nil; manualJoin = nil; error = nil
        if let ssid, !ssid.isEmpty { await wifi?.removeConfiguration(forSSID: ssid) }
    }

    func dismissManualJoin() {
        guard progress == nil, manualJoin != nil else { return }
        manualJoin = nil; error = nil
    }

    func releaseBluetooth() {
        if hasBluetoothLink { trace.record("Closing local Bluetooth link") }
        monitor?.cancel(); monitor = nil
        hasBluetoothLink = false
        apReady = false
        peripheral = nil; peripheralKind = nil
        diagnosticSSID = nil; diagnosticPassword = nil
        bluetooth.disconnect()
    }

    private func trackBluetooth(_ peripheral: any GATTPeripheral, kind: FujiBLEKind) async {
        self.peripheral = peripheral; peripheralKind = kind
        hasBluetoothLink = true
        lastAPState = nil; lastAPError = nil
        trace.record("Bluetooth connected")
        let stream = await peripheral.notifications()
        monitor?.cancel()
        monitor = Task { [weak self] in
            for await event in stream {
                if event.characteristic == FujiBLE.WiFi.readiness {
                    self?.recordValue("AP state update", event.value)
                } else if event.characteristic == FujiBLE.Configuration.stateErrorDetails {
                    self?.recordValue("AP error detail", event.value)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.trace.record("Bluetooth link ended")
            self.hasBluetoothLink = false
            self.peripheral = nil; self.peripheralKind = nil
        }
    }

    func connectDiagnosticBluetooth() async {
        guard !isWorking, !hasBluetoothLink, let savedCamera else { return }
        progress = .diagnosing
        defer { progress = nil }
        trace.record("Opening saved Bluetooth link without registration")
        do {
            let (camera, peripheral) = try await bluetooth.reconnect(savedCamera)
            await trackBluetooth(peripheral, kind: camera.kind)
        } catch { recordBluetoothFailure(error) }
    }

    func runDiagnostic(_ step: DiagnosticStep) async {
        guard !isWorking, let peripheral, let kind = peripheralKind else { return }
        progress = .diagnosing
        defer { progress = nil }
        trace.record("BLE diagnostic: \(step.rawValue)")
        do {
            _ = try await peripheral.discover()
            switch step {
            case .discover: break
            case .pairingKey:
                guard case .basic(let key) = kind else { return }
                try await peripheral.write(key, to: FujiBLE.Pairing.token, withResponse: true)
            case .secureRead:
                _ = try await peripheral.read(FujiBLE.Pairing.status)
            case .secureAck:
                let value = try await peripheral.read(FujiBLE.Pairing.status)
                guard value.count == 4 else { throw FujiBLEError.badLength(expected: 4, actual: value.count) }
                try await peripheral.write(Array(value.prefix(3)) + [0x20], to: FujiBLE.Pairing.status, withResponse: true)
            case .identity:
                let characteristic: GATTCharacteristic
                switch kind {
                case .basic: characteristic = FujiBLE.Pairing.basicIdentity
                case .secure: characteristic = FujiBLE.Pairing.secureIdentity
                }
                try await peripheral.write(Array("Fuji X Open".utf8) + [0], to: characteristic, withResponse: true)
            case .subscribe:
                try await peripheral.setNotify(true, for: FujiBLE.WiFi.readiness)
            case .state:
                recordValue("AP state read", try await peripheral.read(FujiBLE.WiFi.readiness))
            case .error:
                recordValue("AP error detail", try await peripheral.read(FujiBLE.Configuration.stateErrorDetails))
            case .ssid:
                diagnosticSSID = try await readString(FujiBLE.WiFi.ssid, from: peripheral)
            case .password:
                diagnosticPassword = try await readString(FujiBLE.WiFi.password, from: peripheral)
            case .gallery, .remote:
                lastAPState = nil
                lastAPError = nil
                let function: FujiBLE.LaunchFunction = step == .gallery ? .imageBrowsing : .remoteShooting
                let credentials = try await FujiBLEDriver(peripheral: peripheral, trace: trace.reporter("BLE"))
                    .handoff(function: function)
                apReady = !credentials.readinessTimedOut && hasBluetoothLink
                diagnosticSSID = credentials.ssid; diagnosticPassword = credentials.passphrase
                if credentials.readinessTimedOut {
                    trace.record(startupTimeoutMessage)
                    return
                }
            }
            trace.record("BLE diagnostic finished: \(step.rawValue)")
        } catch { recordBluetoothFailure(error) }
    }

    func supports(_ step: DiagnosticStep) -> Bool {
        switch (step, peripheralKind) {
        case (.pairingKey, .basic), (.secureRead, .secure), (.secureAck, .secure): return true
        case (.pairingKey, _), (.secureRead, _), (.secureAck, _): return false
        default: return hasBluetoothLink
        }
    }

    private func recordValue(_ label: String, _ value: [UInt8]) {
        let hex = value.map { String(format: "%02X", $0) }.joined(separator: " ")
        let now = Date.now
        let reading = "\(hex) · \(now.formatted(date: .omitted, time: .standard))"
        if label == "AP error detail" {
            lastAPError = value == [2, 0] ? "Camera busy (\(reading))" : reading
        } else {
            lastAPState = reading
        }
        trace.record("\(label): \(hex)", at: now)
    }

    private func recordBluetoothFailure(_ error: Error) {
        let failure = error as NSError
        trace.record("\(progress?.rawValue ?? "Bluetooth") failed: \(failure.domain) (\(failure.code))")
    }

    private func readString(_ characteristic: GATTCharacteristic, from peripheral: any GATTPeripheral) async throws -> String? {
        let bytes = try await peripheral.read(characteristic)
        let value = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}

import CoreBluetooth
import Foundation
import FujiKit
import OSLog

private enum BluetoothFailure: LocalizedError {
    case unavailable, timedOut, disconnected, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: "Bluetooth isn’t ready. Check Bluetooth permissions and power."
        case .timedOut: "The camera didn’t respond. Wake it, check pairing mode and try again."
        case .disconnected: "The camera’s Bluetooth connection was lost."
        case .busy: "Another Bluetooth operation is in progress."
        }
    }
}

@MainActor
final class CoreCameraBluetooth: NSObject, CameraBluetooth, @preconcurrency CBCentralManagerDelegate {
    private(set) var state: CameraBluetoothState = .checking
    var cameras: [BluetoothCamera] { nearby.cameras }
    private var nearby = NearbyCameras()
    private var pruning: Task<Void, Never>?
    var onChange: (() -> Void)?
    private var central: CBCentralManager?
    private var wantsScan = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var adapter: CoreCameraPeripheral?
    private var pending: CheckedContinuation<any GATTPeripheral, Error>?
    private var connectionID: UUID?

    private func prepare() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func startScanning() {
        wantsScan = true
        prepare()
        prune()
        if state == .poweredOn {
            central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        if pruning == nil {
            pruning = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.prune()
                }
            }
        }
    }

    func stopScanning() {
        wantsScan = false; central?.stopScan()
        pruning?.cancel(); pruning = nil
    }

    private func prune() {
        let stale = nearby.prune()
        guard !stale.isEmpty else { return }
        for id in stale { peripherals[id] = nil }
        onChange?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .checking
        }
        if state == .poweredOn, wantsScan { startScanning() }
        if state != .poweredOn {
            finishConnection(.failure(BluetoothFailure.unavailable))
            adapter?.disconnected(BluetoothFailure.unavailable)
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        var services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                        + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []))
            .map { $0.uuidString.uppercased() }
        if services.contains(FujiBLE.Pairing.secureService) {
            services.append(FujiBLE.Advertising.secure)
        }
        guard let kind = FujiBLE.advertisement(manufacturerData: Array(manufacturer), services: services) else { return }
        let camera = BluetoothCamera(id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Fujifilm camera", kind: kind)
        peripherals[camera.id] = peripheral
        let before = nearby.cameras
        for id in nearby.saw(camera) { peripherals[id] = nil }
        if nearby.cameras != before { onChange?() }
    }

    func reconnect(_ camera: PairedCamera) async throws -> (BluetoothCamera, any GATTPeripheral) {
        prepare()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while state == .checking, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard state == .poweredOn else { throw BluetoothFailure.unavailable }
        if let id = UUID(uuidString: camera.peripheralIdentifier),
           let peripheral = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = peripheral
            let found = BluetoothCamera(id: id, name: camera.name ?? "Fujifilm camera", kind: camera.kind)
            do { return (found, try await connect(found)) }
            catch is CancellationError { throw CancellationError() }
            catch { }
        }
        nearby.removeAll()
        startScanning()
        defer { stopScanning() }
        let scanDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < scanDeadline {
            try Task.checkCancellation()
            guard state == .poweredOn else { throw BluetoothFailure.unavailable }
            if let found = cameras.first(where: {
                if case .secure(let serial) = camera.kind, case .secure(let foundSerial) = $0.kind {
                    return serial == foundSerial
                }
                return $0.id.uuidString == camera.peripheralIdentifier || $0.kind == camera.kind
            }) { return (found, try await connect(found)) }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BluetoothFailure.timedOut
    }

    func connect(_ camera: BluetoothCamera) async throws -> any GATTPeripheral {
        guard state == .poweredOn, let central, let peripheral = peripherals[camera.id] else {
            throw BluetoothFailure.unavailable
        }
        guard pending == nil else { throw BluetoothFailure.busy }
        stopScanning()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; connectionID = id
                adapter = CoreCameraPeripheral(peripheral)
                central.connect(peripheral)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard let self, self.connectionID == id else { return }
                    self.finishConnection(.failure(BluetoothFailure.timedOut))
                    self.disconnect()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.connectionID == id else { return }
                self?.finishConnection(.failure(CancellationError()))
                self?.disconnect()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let adapter, adapter.peripheral === peripheral else { return }
        finishConnection(.success(adapter))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard adapter?.peripheral === peripheral else { return }
        finishConnection(.failure(error ?? BluetoothFailure.disconnected))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard adapter?.peripheral === peripheral else { return }
        adapter?.disconnected(error ?? BluetoothFailure.disconnected)
        finishConnection(.failure(error ?? BluetoothFailure.disconnected))
    }

    private func finishConnection(_ result: Result<any GATTPeripheral, Error>) {
        let continuation = pending
        pending = nil; connectionID = nil
        continuation?.resume(with: result)
    }

    func disconnect() {
        stopScanning()
        finishConnection(.failure(CancellationError()))
        if let adapter {
            adapter.disconnected(BluetoothFailure.disconnected)
            central?.cancelPeripheralConnection(adapter.peripheral)
        }
        adapter = nil
    }
}

@MainActor
final class CoreCameraPeripheral: NSObject, GATTPeripheral, @preconcurrency CBPeripheralDelegate {
    private let logger = Logger(subsystem: "org.fujixopen.app", category: "CameraBluetooth")
    let peripheral: CBPeripheral
    private var characteristics: [GATTCharacteristic: CBCharacteristic] = [:]
    private var inventory: [String: Set<String>]?
    private var requestedService: String?
    private var discoveringServices: Set<String> = []
    private var discoveredInventory: [String: Set<String>] = [:]
    private var pending: CheckedContinuation<[UInt8], Error>?
    private var operationID: UUID?
    private var operationKey = ""
    private var streams: [UUID: AsyncStream<GATTNotification>.Continuation] = [:]

    init(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    private func canonical(_ uuid: CBUUID) -> String {
        let value = uuid.uuidString.uppercased()
        if value.count == 4 { return "0000\(value)-0000-1000-8000-00805F9B34FB" }
        if value.count == 8 { return "\(value)-0000-1000-8000-00805F9B34FB" }
        return value
    }

    private func key(_ characteristic: CBCharacteristic) -> GATTCharacteristic? {
        guard let service = characteristic.service else { return nil }
        return GATTCharacteristic(service: canonical(service.uuid), uuid: canonical(characteristic.uuid))
    }

    private func attribute(_ characteristic: GATTCharacteristic) throws -> CBCharacteristic {
        guard let found = characteristics[characteristic] else {
            throw FujiBLEError.missingCharacteristic(characteristic)
        }
        return found
    }

    private func request(_ key: String, action: () -> Void) async throws -> [UInt8] {
        guard pending == nil else { throw BluetoothFailure.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; operationID = id; operationKey = key
                action()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard self?.operationID == id else { return }
                    self?.finish(.failure(BluetoothFailure.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<[UInt8], Error>) {
        let continuation = pending
        pending = nil; operationID = nil; operationKey = ""
        continuation?.resume(with: result)
    }

    func discover() async throws -> [String: Set<String>] {
        if let inventory { return inventory }
        return try await discoverServices(nil)
    }

    func discover(service: String) async throws -> [String: Set<String>] {
        if let inventory { return inventory.filter { $0.key == service } }
        return try await discoverServices(service)
    }

    private func discoverServices(_ service: String?) async throws -> [String: Set<String>] {
        _ = try await request("discover") {
            requestedService = service
            discoveringServices = []
            discoveredInventory = [:]
            peripheral.discoverServices(service.map { [CBUUID(string: $0)] })
        }
        return discoveredInventory
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard operationKey == "discover" else { return }
        if let error { finish(.failure(error)); return }
        let services = (peripheral.services ?? []).filter { requestedService == nil || canonical($0.uuid) == requestedService }
        discoveredInventory = Dictionary(services.map { (canonical($0.uuid), []) }, uniquingKeysWith: { first, _ in first })
        discoveringServices = Set(discoveredInventory.keys)
        if services.isEmpty { finishDiscovery(); return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard operationKey == "discover" else { return }
        let serviceID = canonical(service.uuid)
        guard discoveringServices.remove(serviceID) != nil else { return }
        if let error { finish(.failure(error)); return }
        for characteristic in service.characteristics ?? [] {
            if let key = key(characteristic) {
                characteristics[key] = characteristic
                discoveredInventory[serviceID, default: []].insert(key.uuid)
            }
        }
        if discoveringServices.isEmpty { finishDiscovery() }
    }

    private func finishDiscovery() {
        if requestedService == nil { inventory = discoveredInventory }
        finish(.success([]))
    }

    func read(_ characteristic: GATTCharacteristic) async throws -> [UInt8] {
        let found = try attribute(characteristic)
        return try await request("read:\(characteristic.uuid)") { peripheral.readValue(for: found) }
    }

    func write(_ value: [UInt8], to characteristic: GATTCharacteristic, withResponse: Bool) async throws {
        let found = try attribute(characteristic)
        if withResponse {
            _ = try await request("write:\(characteristic.uuid)") {
                peripheral.writeValue(Data(value), for: found, type: .withResponse)
            }
        } else {
            try Task.checkCancellation()
            guard peripheral.canSendWriteWithoutResponse else { throw BluetoothFailure.busy }
            peripheral.writeValue(Data(value), for: found, type: .withoutResponse)
        }
    }

    func setNotify(_ enabled: Bool, for characteristic: GATTCharacteristic) async throws {
        let found = try attribute(characteristic)
        _ = try await request("notify:\(characteristic.uuid)") { peripheral.setNotifyValue(enabled, for: found) }
    }

    func notifications() async -> AsyncStream<GATTNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            streams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streams.removeValue(forKey: id) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = key(characteristic) else { return }
        let value = Array(characteristic.value ?? Data())
        if operationKey == "read:\(key.uuid)" {
            if let error { finish(.failure(error)) } else { finish(.success(value)) }
        }
        if error == nil {
            for stream in streams.values { stream.yield(GATTNotification(characteristic: key, value: value)) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = key(characteristic), operationKey == "write:\(key.uuid)" else { return }
        if let error { finish(.failure(error)) } else { finish(.success([])) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = key(characteristic), operationKey == "notify:\(key.uuid)" else { return }
        if let error { finish(.failure(error)) } else { finish(.success([])) }
    }

    func disconnected(_ error: Error) {
        if !operationKey.isEmpty {
            let failure = error as NSError
            let operation = operationKey == "discover" ? requestedService.map { "discover:\($0)" } ?? operationKey : operationKey
            logger.error("Bluetooth operation \(operation, privacy: .public) failed on disconnect (\(failure.domain, privacy: .public):\(failure.code, privacy: .public))")
        }
        finish(.failure(error))
        for stream in streams.values { stream.finish() }
        streams.removeAll()
    }
}

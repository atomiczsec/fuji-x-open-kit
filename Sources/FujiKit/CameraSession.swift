import Foundation

public actor CameraSession {
    public enum InitializationMode: Equatable, Sendable {
        case wirelessCommunication
        case bluetoothXApp
    }

    private let wire: WireConnection
    private var transaction: UInt32 = 1
    private var active = false
    private var ready = false
    private var xApp = false
    private var initialGalleryHandles: [UInt32]?
    private var value = ConnectionTelemetry()
    private var subscribers: [UUID: AsyncStream<ConnectionTelemetry>.Continuation] = [:]
    private let approvalTimeout: Duration
    private let trace: @Sendable (String) -> Void
    public init(transport: any PTPIPTransport, approvalTimeout: Duration = .seconds(10),
                trace: @escaping @Sendable (String) -> Void = { _ in }) {
        wire = WireConnection(transport)
        self.approvalTimeout = approvalTimeout
        self.trace = trace
    }

    public func telemetry() -> AsyncStream<ConnectionTelemetry> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            subscribers[id] = continuation
            continuation.yield(value)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.removeSubscriber(id)
                }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish(_ state: ConnectionTelemetry.State? = nil) async {
        if let state {
            value.state = state
        }
        value.bytesIn = await wire.bytesIn
        value.bytesOut = await wire.bytesOut
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }

    public static func connect(
        host: String, port: UInt16 = FujiWire.commandPort, timeout: TimeInterval = 2,
        name: String = "FujiKit", mode: InitializationMode = .wirelessCommunication
    ) async throws -> CameraSession {
        let session = try await CameraSession(
            transport: SocketTransport.connect(host: host, port: port, timeout: timeout))
        try await session.connect(name: name, mode: mode)
        return session
    }

    public func connect(name: String = "FujiKit", mode: InitializationMode = .wirelessCommunication) async throws {
        guard !active, !ready else {
            throw PTPError.invalidState
        }
        active = true
        defer {
            active = false
        }
        await publish(.connecting)
        do {
            trace("InitCommand sent (\(mode))")
            try await wire.send(FujiWire.initialization(name: name).encoded())
            let acknowledgment = try await wire.packet()
            if acknowledgment.type == .initFail {
                throw PTPError.initializationFailed(try acknowledgment.payload.integer(at: 0))
            }
            guard acknowledgment.type == .initCommandAck else {
                throw PTPError.malformed("Expected InitCommandAck")
            }
            trace("InitCommandAck received")
            try await Task.sleep(nanoseconds: FujiWire.postInitializationDelayNanoseconds)
            await publish(.initializing)
            do {
                _ = try await operation(.openSession, parameters: [1])
            } catch PTPError.response(
                ResponseCode.sessionAlreadyOpen.rawValue)
            {
            }
            try await initializeFuji(mode: mode)
            ready = true
            trace("Session initialized")
            await publish(.ready)
        } catch {
            trace("Setup failed: \(error); closing local socket")
            await wire.close()
            await publish(.failed)
            throw error
        }
    }

    private func initializeFuji(mode initializationMode: InitializationMode) async throws {
        var state = FujiCameraState.waitingForAccess.rawValue
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: approvalTimeout)
        while true {
            guard clock.now < deadline else {
                throw PTPError.timeout
            }
            let events = try await property(.eventsList)
            var reader = DatasetReader(events)
            let count = try reader.read(UInt16.self)
            for _ in 0..<count {
                let code = try reader.read(UInt16.self)
                let eventValue = try reader.read(UInt32.self)
                if code == FujiPropertyCode.cameraState.rawValue {
                    state = eventValue
                }
            }
            guard clock.now < deadline else {
                throw PTPError.timeout
            }
            if state != FujiCameraState.waitingForAccess.rawValue {
                break
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
        }

        var versions: [FujiPropertyCode: UInt32] = [:]
        for code: FujiPropertyCode in [
            .getObjectVersion, .remoteGetObjectVersion, .imageGetVersion, .remoteVersion,
        ] {
            do {
                versions[code] = try await property(code).integer(at: 0)
            } catch PTPError.response(ResponseCode.devicePropNotSupported.rawValue) {
                if initializationMode == .bluetoothXApp {
                    throw PTPError.response(ResponseCode.devicePropNotSupported.rawValue)
                }
            }
        }

        xApp = initializationMode == .bluetoothXApp && (versions[.remoteVersion] ?? 0) >= 0x20007

        let supportsRemote =
            versions[.remoteVersion] != nil
            || state == FujiCameraState.remoteAccess.rawValue
        let mode: FujiClientMode
        if xApp {

            var modeData = Data()
            modeData.appendLE(UInt16(20))
            _ = try await operation(.setDevicePropValue,
                parameters: [UInt32(FujiPropertyCode.clientState.rawValue)], outgoing: modeData)
            _ = try await property(.eventsList)
            _ = try await property(.storageID)
            try await initializeXAppGallery()
            return
        } else if supportsRemote {
            mode = .remote
        } else if state == FujiCameraState.multipleTransfer.rawValue {
            mode = .viewMultiple
        } else if state == FujiCameraState.pcAutoSave.rawValue {
            mode = .oldRemote
        } else {
            mode = .viewAllImages
        }
        var modeData = Data()
        modeData.appendLE(mode.rawValue)
        _ = try await operation(
            .setDevicePropValue,
            parameters: [UInt32(FujiPropertyCode.clientState.rawValue)],
            outgoing: modeData
        )
        var events = DatasetReader(try await property(.eventsList))
        let eventCount = try events.read(UInt16.self)
        for _ in 0..<eventCount {
            let code = try events.read(UInt16.self)
            let eventValue = try events.read(UInt32.self)
            if code == FujiPropertyCode.cameraState.rawValue {
                state = eventValue
            }
        }
        if initializationMode == .bluetoothXApp { _ = try? await property(.storageID) }
        if state == FujiCameraState.multipleTransfer.rawValue {
            return
        }

        let versionProperty: FujiPropertyCode
        if state == FujiCameraState.pcAutoSave.rawValue {
            versionProperty = .autoSaveVersion
        } else if versions[.remoteVersion] != nil {
            versionProperty = .remoteVersion
        } else {
            versionProperty = .getObjectVersion
        }
        var versionData = Data()
        if versionProperty == .remoteVersion {
            versionData.appendLE(FujiWire.cameraConnectRemoteVersion)
        } else {
            versionData = try await property(versionProperty)
        }
        _ = try await operation(
            .setDevicePropValue,
            parameters: [UInt32(versionProperty.rawValue)],
            outgoing: versionData
        )
    }

    private func initializeXAppGallery() async throws {
        let version = try await property(.remotePhotoViewExVersion)
        _ = try await operation(.setDevicePropValue,
            parameters: [UInt32(FujiPropertyCode.remotePhotoViewExVersion.rawValue)], outgoing: version)
        try await setProperty16(.compressSmall, value: 0)
        try await setProperty16(.enableCorrectFileSize, value: 0)
        _ = try await property(.storageID)
        initialGalleryHandles = try await readXAppGalleryHandles()
    }

    private func readXAppGalleryHandles() async throws -> [UInt32] {
        do {
            _ = try await operation(.getPreviewObjectInfo, parameters: [0x10000001])
        } catch PTPError.response {
            return []
        }
        _ = try await operation(.getPreviewThumb, parameters: [0x10000001])
        _ = try await operation(.getFilterProps)
        _ = try await property(.filterState)
        _ = try await operation(.getImageImportDates, parameters: [0, 30000])
        _ = try await property(.filteredObjectCount)
        var reader = DatasetReader(try await property(.filteredObjectHandles))
        return try reader.array()
    }

    private func setProperty16(_ code: FujiPropertyCode, value: UInt16) async throws {
        var data = Data()
        data.appendLE(value)
        _ = try await operation(.setDevicePropValue, parameters: [UInt32(code.rawValue)], outgoing: data)
    }

    private func property(_ code: FujiPropertyCode) async throws -> Data {
        try await operation(.getDevicePropValue, parameters: [UInt32(code.rawValue)])
    }

    private func operation(
        _ code: OperationCode, parameters: [UInt32] = [], outgoing: Data? = nil,
        sink: (@Sendable (Data) async throws -> Void)? = nil
    ) async throws -> Data {
        try await exchange(code, parameters: parameters, outgoing: outgoing, sink: sink).data
    }

    private func exchange(
        _ code: OperationCode, parameters: [UInt32] = [], outgoing: Data? = nil,
        sink: (@Sendable (Data) async throws -> Void)? = nil, maximumDataLength: Int? = nil
    ) async throws -> (data: Data, bytesReceived: Int) {
        let id = transaction
        transaction &+= 1
        trace("tx \(id) opcode \(String(code.rawValue, radix: 16))"
            + ((code == .getDevicePropValue || code == .setDevicePropValue)
                ? parameters.first.map { " property \(String($0, radix: 16))" } ?? "" : ""))
        let started = Date()
        var transferBytes = 0
        let reportsTransferRate = value.state != .transferring || code == .getObject || code == .getPartialObject
        if reportsTransferRate { value.bytesPerSecond = 0 }
        var parameterData = Data()
        for parameter in parameters {
            parameterData.appendLE(parameter)
        }
        try await wire.send(
            FujiContainer(
                .command, code: code.rawValue, transaction: id,
                payload: parameterData
            ).encoded())
        if let outgoing {
            try await wire.send(
                FujiContainer(.data, code: code.rawValue, transaction: id, payload: outgoing)
                    .encoded())
        }
        var result = Data()
        var receivedData = false
        while true {
            let header = try await wire.header()
            guard header.transaction == id else {
                throw PTPError.malformed("Transaction mismatch")
            }
            if header.kind == .data {
                guard !receivedData, header.code == code.rawValue else {
                    throw PTPError.malformed("Unexpected data container")
                }
                receivedData = true
                if let maximumDataLength, header.length > maximumDataLength {
                    throw PTPError.malformed("Invalid partial object length")
                }
                guard sink != nil || header.length <= 16 * 1024 * 1024 else {
                    throw PTPError.malformed("Dataset too large")
                }
                var remaining = header.length
                while remaining > 0 {
                    let chunk = try await wire.read(min(64 * 1024, remaining))
                    remaining -= chunk.count
                    transferBytes += chunk.count
                    if let sink {
                        try await sink(chunk)
                    } else {
                        result.append(chunk)
                    }
                    if reportsTransferRate {
                        value.bytesPerSecond =
                            Double(transferBytes)
                            / max(Date().timeIntervalSince(started), 0.000001)
                    }
                    await publish()
                }
            } else {
                guard header.kind == .response, header.length <= 20, header.length % 4 == 0 else {
                    throw PTPError.malformed("Expected response")
                }
                _ = try await wire.read(header.length)
                trace("rx \(id) response \(String(header.code, radix: 16))")
                value.lastRoundTripTime = Date().timeIntervalSince(started)
                if reportsTransferRate {
                    value.bytesPerSecond =
                        Double(transferBytes) / max(value.lastRoundTripTime, 0.000001)
                }
                await publish()
                guard header.code == ResponseCode.ok.rawValue else {
                    throw PTPError.response(header.code)
                }
                return (result, transferBytes)
            }
        }
    }

    private func perform(
        _ code: OperationCode, parameters: [UInt32] = [],
        sink: (@Sendable (Data) async throws -> Void)? = nil
    ) async throws -> Data {
        try await performTransaction(transferring: sink != nil) {
            try await self.operation(code, parameters: parameters, sink: sink)
        }
    }

    private func performTransaction(
        transferring: Bool = false, _ body: () async throws -> Data
    ) async throws -> Data {
        guard ready else {
            throw PTPError.invalidState
        }
        guard !active else {
            throw PTPError.busy
        }
        active = true
        defer {
            active = false
        }
        if transferring {
            value.bytesPerSecond = 0
            await publish(.transferring)
        }
        do {
            let result = try await body()
            await publish(.ready)
            return result
        } catch let error as PTPError {
            if case .response = error {
                await publish(.ready)
            } else {
                ready = false
                trace("Transaction failed: \(error); closing local socket")
                await wire.close()
                await publish(.failed)
            }
            throw error
        } catch {
            ready = false
            trace("Transaction failed: \(error); closing local socket")
            await wire.close()
            await publish(.failed)
            throw error
        }
    }

    public func getDeviceInfo() async throws -> DeviceInfo {
        try await getDeviceInfo(fallbackModel: nil)
    }

    public func getDeviceInfo(fallbackModel: String?) async throws -> DeviceInfo {
        let data = try await perform(.getDeviceInfo)
        do {
            return try DeviceInfo(data: data)
        } catch PTPError.malformed(let reason) {
            guard xApp, let fallbackModel else { throw PTPError.malformed(reason) }
            trace("Device information dataset (\(data.count) bytes): \(reason). Using camera display name.")
            return DeviceInfo(model: fallbackModel)
        }
    }

    public func getStorageIDs() async throws -> [UInt32] {
        var reader = try await DatasetReader(perform(.getStorageIDs))
        return try reader.array()
    }

    public func getStorageInfo(_ id: UInt32) async throws -> StorageInfo {
        try await StorageInfo(data: perform(.getStorageInfo, parameters: [id]))
    }

    public func batteryLevel() async throws -> UInt8 {
        guard let level = try await reportedBatteryLevel() else {
            throw PTPError.malformed("Missing battery level")
        }
        return level
    }

    public func reportedBatteryLevel() async throws -> UInt8? {
        let payload = try await perform(
            .getDevicePropValue, parameters: [UInt32(PTPPropertyCode.batteryLevel.rawValue)]
        )
        return payload.first
    }

    public func getObjectHandles(storageID: UInt32 = .max) async throws -> [UInt32] {
        if xApp {
            var handles: [UInt32] = []
            _ = try await performTransaction {
                let snapshot: [UInt32]
                if let initialGalleryHandles {
                    snapshot = initialGalleryHandles
                    self.initialGalleryHandles = nil
                } else {
                    snapshot = try await readXAppGalleryHandles()
                }
                for handle in snapshot {
                    if storageID == .max {
                        handles.append(handle)
                    } else {
                        let info = try await ObjectInfo(data: self.operation(.getObjectInfo, parameters: [handle]))
                        if info.storageID == storageID { handles.append(handle) }
                    }
                }
                return Data()
            }
            return handles
        }
        var reader = try await DatasetReader(
            perform(.getObjectHandles, parameters: [storageID, 0, 0]))
        return try reader.array()
    }

    public func getObjectInfo(_ handle: UInt32) async throws -> ObjectInfo {
        try await ObjectInfo(data: perform(.getObjectInfo, parameters: [handle]))
    }

    public func getThumbnail(_ handle: UInt32) async throws -> Data {
        try await performTransaction {
            try await self.exchange(.getThumb, parameters: [handle], maximumDataLength: 8 * 1024 * 1024).data
        }
    }

    public func getObject(_ handle: UInt32, sink: @escaping @Sendable (Data) async throws -> Void)
        async throws
    {
        if xApp {
            _ = try await performTransaction(transferring: true) {
                try await self.downloadXAppObject(handle, sink: sink)
                return Data()
            }
            return
        }
        _ = try await perform(.getObject, parameters: [handle], sink: sink)
    }

    private func downloadXAppObject(_ handle: UInt32, sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await setProperty16(.compressSmall, value: 2)
        do {
            let info = try await ObjectInfo(data: operation(.getObjectInfo, parameters: [handle]))
            var offset: UInt32 = 0
            let started = Date()
            while offset < info.size {
                try Task.checkCancellation()
                let count = min(info.size - offset, 0x100000)
                let result = try await exchange(.getPartialObject, parameters: [handle, offset, count],
                    sink: sink, maximumDataLength: Int(count))
                guard result.bytesReceived > 0 else {
                    throw PTPError.malformed("Invalid partial object length")
                }
                offset += UInt32(result.bytesReceived)
            }
            value.bytesPerSecond = Double(offset) / max(Date().timeIntervalSince(started), 0.000001)
        } catch {
            try? await setProperty16(.compressSmall, value: 2)
            throw error
        }
        try await setProperty16(.compressSmall, value: 2)
    }

    public func close() async throws {
        guard !active else {
            throw PTPError.busy
        }
        trace("Local session close requested")
        if ready {
            do {
                _ = try await perform(.closeSession)
            } catch {
                ready = false
                await wire.close()
                await publish(.disconnected)
                throw error
            }
        }
        ready = false
        await wire.close()
        await publish(.disconnected)
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }
}

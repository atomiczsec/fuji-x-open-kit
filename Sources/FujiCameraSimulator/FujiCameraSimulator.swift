import Foundation
import FujiKit

public struct FujiCameraSimulator: Sendable {
    public actor Gallery {
        public private(set) var objects: [UInt32: Data]
        public init(objects: [UInt32: Data] = FujiCameraSimulator.objects) { self.objects = objects }
        public func setObject(_ data: Data?, for handle: UInt32) { objects[handle] = data }
    }

    public struct Configuration: Sendable {
        public var objects = FujiCameraSimulator.objects
        public var gallery: Gallery?
        public var filenames: [UInt32: String] = [:]
        public var thumbnails: [UInt32: Data] = [:]
        public var initializationFailure: UInt32?
        public var rejectedOperation: UInt16?
        public var responseCode: UInt16 = ResponseCode.generalError.rawValue
        public var batteryPayload = Data([87])
        public var deviceInfoPayload: Data?
        public var xApp = false
        public var remoteVersion: UInt32 = 0x2000C
        public var cardInserted = true
        public init() {
        }

        public init(objectsDirectory: URL) throws {
            self.init()
            objects = [:]
            let files = try FileManager.default.contentsOfDirectory(
                at: objectsDirectory, includingPropertiesForKeys: [.isRegularFileKey]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ["jpg", "jpeg", "raf"].contains(ext),
                    try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else { continue }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count <= Int(UInt32.max) else {
                    throw PTPError.malformed("Object exceeds PTP size limit")
                }
                let id = UInt32(objects.count + 1)
                objects[id] = data
                filenames[id] = file.lastPathComponent
            }
        }
    }

    public static let objects: [UInt32: Data] = [
        1: Data([0xff, 0xd8, 0xff, 0xd9]),
        2: Data("FUJIFILMCCD-RAW ".utf8) + Data(repeating: 0x52, count: 180_000),
    ]
    public let configuration: Configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func serve(transport: any PTPIPTransport) async throws {
        let wire = WireConnection(transport)
        do {
            try await serve(wire)
        } catch PTPError.disconnected {
        } catch {
            await wire.close()
            throw error
        }
        await wire.close()
    }

    private func serve(_ wire: WireConnection) async throws {
        let request = try await wire.packet()
        guard request.type == .initCommandRequest,
            request.payload.count == FujiWire.initializationPayloadSize,
            try request.payload.integer(at: 0, as: UInt32.self) == FujiWire.protocolVersion
        else {
            throw PTPError.malformed("Invalid Fuji initialization")
        }
        if let failure = configuration.initializationFailure {
            var data = Data()
            data.appendLE(failure)
            try await wire.send(Packet(.initFail, payload: data).encoded())
            return
        }
        try await wire.send(
            Packet(
                .initCommandAck, payload: FujiWire.initialization(name: "Fuji Simulator").payload
            ).encoded())
        var opened = false
        let initialObjects = await configuration.gallery?.objects ?? configuration.objects
        var initialization = configuration.xApp ? xAppInitialization(objects: initialObjects) : []
        let modernXApp = configuration.xApp && configuration.remoteVersion >= 0x20007
        var downloadPrepared = false
        var downloadHandle: UInt32?
        var downloadOffset = 0
        while true {
            let command = try await wire.container()
            let objects = await configuration.gallery?.objects ?? configuration.objects
            guard command.kind == .command else {
                throw PTPError.malformed("Expected command container")
            }
            var response = ResponseCode.ok.rawValue
            var payload: Data?
            let parameter = (try? command.payload.integer(at: 0, as: UInt32.self)) ?? 0
            var outgoing: Data?
            if command.code == OperationCode.setDevicePropValue.rawValue {
                let data = try await wire.container()
                guard data.kind == .data, data.code == command.code,
                    data.transaction == command.transaction
                else {
                    throw PTPError.malformed("Invalid property data")
                }
                outgoing = data.payload
            }
            if modernXApp, initialization.isEmpty,
                command.code == OperationCode.getPreviewObjectInfo.rawValue {
                initialization = xAppGalleryListing(objects: objects)
            }
            if command.code == configuration.rejectedOperation {
                response = configuration.responseCode
            } else if !opened && command.code != OperationCode.openSession.rawValue {
                response = ResponseCode.sessionNotOpen.rawValue
            } else if opened, !initialization.isEmpty, command.code != OperationCode.closeSession.rawValue {
                let step = initialization.removeFirst()
                guard command.code == step.code.rawValue, command.payload == step.parameters,
                    outgoing == step.outgoing else {
                    throw PTPError.malformed("Unexpected XApp initialization step: \(command.code), property \(parameter)")
                }
                payload = step.reply
                response = step.response
            } else {
                switch OperationCode(rawValue: command.code) {
                case .openSession:
                    response =
                        opened ? ResponseCode.sessionAlreadyOpen.rawValue : ResponseCode.ok.rawValue
                    opened = true
                case .closeSession:
                    opened = false
                case .getDeviceInfo:
                    payload = configuration.deviceInfoPayload ?? Self.deviceInfo()
                case .getStorageIDs:
                    payload = Self.array([0x10001])
                case .getStorageInfo:
                    payload = Self.storageInfo()
                case .getObjectHandles:
                    if modernXApp { response = ResponseCode.operationNotSupported.rawValue }
                    else { payload = Self.array(objects.keys.sorted()) }
                case .getObjectInfo:
                    if let object = objects[parameter] {
                        payload = Self.objectInfo(
                            parameter, size: object.count, filename: configuration.filenames[parameter])
                        if downloadPrepared {
                            downloadHandle = parameter
                            downloadOffset = 0
                        }
                    } else {
                        response = ResponseCode.invalidObjectHandle.rawValue
                    }
                case .getObject:
                    if modernXApp { response = ResponseCode.operationNotSupported.rawValue }
                    else { payload = objects[parameter] }
                    if payload == nil && !modernXApp {
                        response = ResponseCode.invalidObjectHandle.rawValue
                    }
                case .getThumb:
                    if let thumbnail = configuration.thumbnails[parameter] {
                        payload = thumbnail
                    } else {
                        response = ResponseCode.noThumbnailPresent.rawValue
                    }
                case .getPartialObject:
                    guard modernXApp, downloadPrepared, downloadHandle == parameter,
                        let object = objects[parameter],
                        try command.payload.integer(at: 4, as: UInt32.self) == UInt32(downloadOffset),
                        try command.payload.integer(at: 8, as: UInt32.self) == UInt32(min(object.count - downloadOffset, 0x100000))
                    else { throw PTPError.malformed("Invalid XApp download sequence") }
                    let count = min(object.count - downloadOffset, 0x100000)
                    payload = Data(object.dropFirst(downloadOffset).prefix(count))
                    downloadOffset += count
                case .getDevicePropValue:
                    switch parameter {
                    case UInt32(PTPPropertyCode.batteryLevel.rawValue):
                        payload = configuration.batteryPayload
                    case UInt32(FujiPropertyCode.eventsList.rawValue):
                        var data = Data()
                        data.appendLE(UInt16(1))
                        data.appendLE(FujiPropertyCode.cameraState.rawValue)
                        data.appendLE(FujiCameraState.fullAccess.rawValue)
                        payload = data
                    case UInt32(FujiPropertyCode.imageGetVersion.rawValue),
                        UInt32(FujiPropertyCode.getObjectVersion.rawValue),
                        UInt32(FujiPropertyCode.remoteGetObjectVersion.rawValue):
                        var data = Data()
                        data.appendLE(UInt32(1))
                        payload = data
                    default:
                        response = ResponseCode.devicePropNotSupported.rawValue
                    }
                case .setDevicePropValue:
                    if modernXApp {
                        guard parameter == UInt32(FujiPropertyCode.compressSmall.rawValue),
                            outgoing == Self.integer16(2) else {
                            throw PTPError.malformed("Unexpected XApp property write")
                        }
                        if let handle = downloadHandle {
                            guard downloadOffset == objects[handle]?.count else {
                                throw PTPError.malformed("Incomplete XApp download")
                            }
                            downloadHandle = nil
                            downloadPrepared = false
                        } else {
                            downloadPrepared = true
                        }
                    }
                case .initiateOpenCapture:
                    break
                case .getFilterProps, .getImageImportDates, .getPreviewObjectInfo, .getPreviewThumb:
                    response = ResponseCode.operationNotSupported.rawValue
                case nil:
                    response = ResponseCode.operationNotSupported.rawValue
                }
            }
            if let payload {
                let container = FujiContainer(
                    .data, code: command.code, transaction: command.transaction, payload: payload
                ).encoded()
                for offset in stride(from: 0, to: container.count, by: 8192) {
                    try await wire.send(Data(container.dropFirst(offset).prefix(8192)))
                }
            }
            try await wire.send(
                FujiContainer(.response, code: response, transaction: command.transaction).encoded()
            )
            if command.code == OperationCode.closeSession.rawValue {
                return
            }
        }
    }

    private struct InitializationStep {
        let code: OperationCode
        let parameters: Data
        let outgoing: Data?
        let reply: Data?
        let response: UInt16

        init(_ code: OperationCode, _ parameters: [UInt32] = [], outgoing: Data? = nil,
            reply: Data? = nil, response: UInt16 = ResponseCode.ok.rawValue) {
            self.code = code
            self.parameters = parameters.reduce(into: Data()) { $0.appendLE($1) }
            self.outgoing = outgoing
            self.reply = reply
            self.response = response
        }
    }

    private func xAppInitialization(objects: [UInt32: Data]) -> [InitializationStep] {
        func read(_ code: FujiPropertyCode, _ value: UInt32) -> InitializationStep {
            InitializationStep(.getDevicePropValue, [UInt32(code.rawValue)], reply: Self.integer32(value))
        }
        func write(_ code: FujiPropertyCode, _ data: Data) -> InitializationStep {
            InitializationStep(.setDevicePropValue, [UInt32(code.rawValue)], outgoing: data)
        }
        var events = Data()
        events.appendLE(UInt16(1))
        events.appendLE(FujiPropertyCode.cameraState.rawValue)
        events.appendLE(FujiCameraState.fullAccess.rawValue)
        let event = InitializationStep(.getDevicePropValue, [UInt32(FujiPropertyCode.eventsList.rawValue)], reply: events)
        let modern = configuration.remoteVersion >= 0x20007
        var steps: [InitializationStep] = [event,
            read(.getObjectVersion, 1), read(.remoteGetObjectVersion, 1), read(.imageGetVersion, 1),
            read(.remoteVersion, configuration.remoteVersion),
            write(.clientState, Self.integer16(modern ? 20 : 5)), event, read(.storageID, 1)]
        guard modern else {
            steps.append(write(.remoteVersion, Self.integer32(FujiWire.cameraConnectRemoteVersion)))
            return steps
        }
        return steps + xAppGalleryInitialization(objects: objects)
    }

    private func xAppGalleryInitialization(objects: [UInt32: Data]) -> [InitializationStep] {
        func read(_ code: FujiPropertyCode, _ value: UInt32) -> InitializationStep {
            InitializationStep(.getDevicePropValue, [UInt32(code.rawValue)], reply: Self.integer32(value))
        }
        func write(_ code: FujiPropertyCode, _ data: Data) -> InitializationStep {
            InitializationStep(.setDevicePropValue, [UInt32(code.rawValue)], outgoing: data)
        }
        return [read(.remotePhotoViewExVersion, 3), write(.remotePhotoViewExVersion, Self.integer32(3)),
            write(.compressSmall, Self.integer16(0)), write(.enableCorrectFileSize, Self.integer16(0)),
            read(.storageID, 1)] + xAppGalleryListing(objects: objects)
    }

    private func xAppGalleryListing(objects: [UInt32: Data]) -> [InitializationStep] {
        func read(_ code: FujiPropertyCode, _ value: UInt32) -> InitializationStep {
            InitializationStep(.getDevicePropValue, [UInt32(code.rawValue)], reply: Self.integer32(value))
        }
        var steps = [InitializationStep(.getPreviewObjectInfo, [0x10000001], reply: configuration.cardInserted ? Data() : nil,
                response: configuration.cardInserted ? ResponseCode.ok.rawValue : 0x2013)]
        guard configuration.cardInserted else { return steps }
        steps += [InitializationStep(.getPreviewThumb, [0x10000001], reply: Data()),
            InitializationStep(.getFilterProps, reply: Data()), read(.filterState, 0),
            InitializationStep(.getImageImportDates, [0, 30000], reply: Data()),
            read(.filteredObjectCount, UInt32(objects.count)),
            InitializationStep(.getDevicePropValue, [UInt32(FujiPropertyCode.filteredObjectHandles.rawValue)],
                reply: Self.array(objects.keys.sorted()))]
        return steps
    }

    private static func integer16(_ value: UInt16) -> Data {
        var data = Data()
        data.appendLE(value)
        return data
    }

    private static func integer32(_ value: UInt32) -> Data {
        var data = Data()
        data.appendLE(value)
        return data
    }

    private static func array(_ values: [UInt32]) -> Data {
        var data = Data()
        data.appendLE(UInt32(values.count))
        for value in values {
            data.appendLE(value)
        }
        return data
    }

    private static func deviceInfo() -> Data {
        var data = Data()
        data.appendLE(UInt16(100))
        data.appendLE(UInt32(14))
        data.appendLE(UInt16(100))
        data.appendPTPString("FujiKit simulator")
        data.appendLE(UInt16(0))
        for _ in 0..<5 {
            data.appendLE(UInt32(0))
        }
        for value in ["FUJIFILM", "X-SIM", "1.0", "SIM0001"] {
            data.appendPTPString(value)
        }
        return data
    }

    private static func storageInfo() -> Data {
        var data = Data()
        for value: UInt16 in [3, 2, 0] {
            data.appendLE(value)
        }
        data.appendLE(UInt64(8_000_000_000))
        data.appendLE(UInt64(7_000_000_000))
        data.appendLE(UInt32(1000))
        data.appendPTPString("Simulated SD")
        data.appendPTPString("FUJI")
        return data
    }

    private static func objectInfo(_ handle: UInt32, size: Int, filename: String? = nil) -> Data {
        let name = filename ?? (handle == 1 ? "DSCF0001.JPG" : "DSCF0002.RAF")
        let raw = name.lowercased().hasSuffix(".raf")
        var data = Data()
        data.appendLE(UInt32(0x10001))
        data.appendLE((raw ? ObjectFormat.raf : .jpeg).rawValue)
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(size))
        data.append(Data(repeating: 0, count: 52 - data.count))
        data.appendPTPString(name)
        for _ in 0..<3 {
            data.appendPTPString("")
        }
        return data
    }
}

import Foundation
import ImageIO
import Observation
import UIKit
import FujiKit

protocol CameraConnection: Sendable {
    func connect(name: String, mode: CameraSession.InitializationMode) async throws
    func getDeviceInfo(fallbackModel: String?) async throws -> DeviceInfo
    func reportedBatteryLevel() async throws -> UInt8?
    func getStorageIDs() async throws -> [UInt32]
    func getStorageInfo(_ id: UInt32) async throws -> StorageInfo
    func getObjectHandles(storageID: UInt32) async throws -> [UInt32]
    func getObjectInfo(_ handle: UInt32) async throws -> ObjectInfo
    func getThumbnail(_ handle: UInt32) async throws -> Data
    func getObject(_ handle: UInt32, sink: @escaping @Sendable (Data) async throws -> Void) async throws
    func telemetry() async -> AsyncStream<ConnectionTelemetry>
    func close() async throws
}

extension CameraSession: CameraConnection {}

protocol PhotoImporting: Sendable {
    func authorize() async throws
    func importPhoto(at url: URL, originalFilename: String) async throws
}

struct CameraObject: Identifiable {
    let id: UInt32
    let info: ObjectInfo
    var format: ObjectFormat? {
        ObjectFormat(rawValue: info.format) ?? (info.filename.lowercased().hasSuffix(".raf") ? .raf : nil)
    }
    var isRAW: Bool { format == .raf }
}

struct CameraStorage: Identifiable {
    let id: UInt32
    let info: StorageInfo
}

actor TransferFile {
    let url: URL
    private var handle: FileHandle?
    init(filename: String) throws {
        let suffix = URL(fileURLWithPath: filename).pathExtension
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    func write(_ data: Data) throws { try handle?.write(contentsOf: data) }
    func finish() throws { try handle?.close(); handle = nil }
    func remove() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor @Observable
final class CameraConnectionTrace {
    private(set) var lines: [String] = []

    func record(_ message: String, at date: Date = .now) {
        lines.append("\(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(message)")
        if lines.count > 250 { lines.removeFirst(lines.count - 250) }
    }

    nonisolated func reporter(_ subsystem: String) -> @Sendable (String) -> Void {
        { [weak self] message in
            let timestamp = Date.now
            Task { @MainActor in self?.record("\(subsystem): \(message)", at: timestamp) }
        }
    }
}

@MainActor @Observable
final class CameraModel {
    enum Filter: String, CaseIterable { case all = "All", jpeg = "JPEG", raw = "RAW" }
    var host = "192.168.0.1"
    var port = "55740"
    var candidates: [DiscoveredCamera] = []
    var device: DeviceInfo?
    var battery: UInt8?
    var storages: [CameraStorage] = []
    var objects: [CameraObject] = []
    var selected: Set<UInt32> = []
    var filter: Filter = .all
    var telemetry = ConnectionTelemetry()
    var busy = false
    private(set) var authorizing = false
    private(set) var restoringConnection = false
    var searching = false
    var error: String?
    var searched = false
    var completed: Set<UInt32> = []
    var fileProgress: [UInt32: Double] = [:]
    var overallProgress: Double = 0
    var transferSummary: String?
    private(set) var loadingThumbnail = false
    private(set) var galleryRevision = 0
    let trace = CameraConnectionTrace()
    @ObservationIgnored private var session: (any CameraConnection)?
    @ObservationIgnored private var connectedCamera: DiscoveredCamera?
    @ObservationIgnored private var resumeCamera: DiscoveredCamera?
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var telemetryTask: Task<Void, Never>?
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var statusRefresh: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private let thumbnails: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 128
        return cache
    }()
    @ObservationIgnored private var missingThumbnails: Set<UInt32> = []
    @ObservationIgnored private var thumbnailUnsupported = false
    @ObservationIgnored private let keepaliveSleep: @Sendable () async throws -> Void
    @ObservationIgnored private let discovery: @Sendable (String, UInt16) -> any CameraDiscovering
    @ObservationIgnored private let makeSession: @Sendable (String, UInt16) async throws -> any CameraConnection
    @ObservationIgnored private let importer: any PhotoImporting
    @ObservationIgnored private var initializationMode: CameraSession.InitializationMode = .wirelessCommunication
    @ObservationIgnored lazy var pairing = CameraPairing(bluetooth: CoreCameraBluetooth(), trace: trace,
        connectWhenReachable: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.connectGallery(waitForRoute: true)
        }) { [weak self] in
        guard let self else { throw PTPError.disconnected }
        try await self.connectAfterBluetoothHandoff()
    }

    init(importer: any PhotoImporting = PhotoLibraryImporter(),
         keepaliveSleep: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .seconds(5))
         },
         discovery: @escaping @Sendable (String, UInt16) -> any CameraDiscovering = {
             CameraDiscovery(hosts: [$0], port: $1)
         },
         makeSession: (@Sendable (String, UInt16) async throws -> any CameraConnection)? = nil) {
        self.importer = importer
        self.keepaliveSleep = keepaliveSleep
        self.discovery = discovery
        let report = trace.reporter("PTP")
        self.makeSession = makeSession ?? { host, port in
            try await CameraSession(transport: SocketTransport.connect(host: host, port: port), trace: report)
        }
    }

    var visibleObjects: [CameraObject] {
        objects.filter { filter == .all || (filter == .raw ? $0.format == .raf : $0.format == .jpeg) }
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard backgrounded != isBackgrounded else { return }
        isBackgrounded = backgrounded
        if backgrounded {
            if let connectedCamera { resumeCamera = connectedCamera }
        } else {
            resumeIfNeeded()
        }
    }

    private func resumeIfNeeded() {
        guard !isBackgrounded, !busy, let candidate = resumeCamera else { return }
        resumeCamera = nil
        busy = true; restoringConnection = true
        Task { await restoreConnection(to: candidate) }
    }

    private func restoreConnection(to candidate: DiscoveredCamera) async {
        defer {
            restoringConnection = false
            finishOperation()
        }
        if !isBackgrounded, let session {
            do {
                try await readBattery(from: session)
                return
            } catch {
                clearConnection()
                try? await session.close()
            }
        }
        guard !isBackgrounded else {
            resumeCamera = candidate
            return
        }
        error = nil
        do { try await openConnection(to: candidate) }
        catch {
            self.error = "Couldn’t reconnect: \(String(describing: error)). Check camera Wi-Fi and reconnect."
        }
    }

    private func finishOperation() {
        busy = false
        resumeIfNeeded()
    }

    func find() async {
        guard !busy else { return }
        guard let number = UInt16(port), number > 0 else { error = "Enter a port from 1 to 65535."; return }
        busy = true; searching = true; error = nil
        defer { finishOperation() }
        candidates = await discovery(host.trimmingCharacters(in: .whitespacesAndNewlines), number).discover()
        searched = true; searching = false
    }

    func connect(_ candidate: DiscoveredCamera) async {
        guard !busy, session == nil else { return }
        busy = true; error = nil
        initializationMode = .wirelessCommunication
        defer { finishOperation() }
        do { try await openConnection(to: candidate) }
        catch { self.error = String(describing: error) }
    }

    func connectAfterBluetoothHandoff() async throws {
        _ = try await connectGallery(waitForRoute: false)
    }

    func connectGallery(waitForRoute: Bool) async throws -> Bool {
        guard !busy, session == nil else { throw PTPError.busy }
        busy = true; error = nil
        initializationMode = .bluetoothXApp
        defer { finishOperation() }
        return try await openConnection(to: DiscoveredCamera(host: "192.168.0.1", port: FujiWire.commandPort),
                                        waitForRoute: waitForRoute)
    }

    func openGalleryOnExistingWiFi() async {
        guard !busy, session == nil else { return }
        do { try await connectAfterBluetoothHandoff() }
        catch {
            self.error = "Couldn’t open the gallery: \(String(describing: error)). Stay on the camera’s Wi-Fi and try again."
        }
    }

    @discardableResult
    private func openConnection(to candidate: DiscoveredCamera, waitForRoute: Bool = false) async throws -> Bool {
        var connection: (any CameraConnection)?
        var stage = "TCP open"
        do {
            trace.record("Opening TCP to \(candidate.host):\(candidate.port)")
            let camera = try await makeSession(candidate.host, candidate.port)
            connection = camera
            try Task.checkCancellation()
            trace.record("TCP open")
            telemetryTask = Task { [weak self] in
                for await value in await camera.telemetry() {
                    guard !Task.isCancelled else { break }
                    self?.telemetry = value
                    if value.state == .failed, let self, !self.busy {
                        self.busy = true
                        await self.connectionLost(PTPError.disconnected)
                        self.finishOperation()
                        break
                    }
                }
            }
            stage = "PTP initialization"
            try await camera.connect(name: "Fuji X Open", mode: initializationMode)
            stage = "device information"
            let fallback = initializationMode == .bluetoothXApp ? pairing.savedCamera?.name ?? "Fujifilm camera" : nil
            let info = try await camera.getDeviceInfo(fallbackModel: fallback)
            stage = "battery status"
            try await readBattery(from: camera)
            stage = "storage enumeration"
            var storageValues: [CameraStorage] = []
            do {
                for id in try await camera.getStorageIDs() {
                    storageValues.append(CameraStorage(id: id, info: try await camera.getStorageInfo(id)))
                }
            } catch PTPError.response(ResponseCode.operationNotSupported.rawValue) where initializationMode == .bluetoothXApp {
                trace.record("Standard storage query unsupported (2005). Continuing with XApp gallery.")
            }
            try Task.checkCancellation()
            storages = storageValues
            session = camera; device = info
            connectedCamera = candidate
            trace.record("Gallery connection ready")
            if isBackgrounded { resumeCamera = candidate }
            startKeepalive()
            return true
        } catch {
            if waitForRoute, connection == nil, let failure = error as? PTPError {
                switch failure {
                case .timeout, .socket(EHOSTUNREACH), .socket(ENETUNREACH), .socket(ENETDOWN),
                     .socket(ECONNREFUSED), .socket(ETIMEDOUT), .socket(EHOSTDOWN):
                    trace.record("Waiting for camera network (\(failure))")
                    return false
                default: break
                }
            }
            trace.record("\(stage) failed: \(Self.transportFailure(error))")
            if connection != nil { trace.record("Cleaning up local PTP session after setup failure") }
            try? await connection?.close()
            telemetryTask?.cancel()
            keepaliveTask?.cancel(); keepaliveTask = nil
            battery = nil; storages = []
            throw error
        }
    }

    func loadObjects() async {
        guard !busy, !authorizing, let session else { return }
        busy = true; error = nil
        defer { finishOperation() }
        do {
            var values: [CameraObject] = []
            for id in try await session.getObjectHandles(storageID: .max) {
                values.append(CameraObject(id: id, info: try await session.getObjectInfo(id)))
            }
            objects = values
            galleryRevision += 1
            thumbnails.removeAllObjects()
            missingThumbnails.removeAll()
            selected.formIntersection(values.map(\.id))
        } catch { await handleCameraError(error) }
    }

    func thumbnail(for object: CameraObject) async -> UIImage? {
        let revision = galleryRevision
        while busy || authorizing {
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return nil }
        }
        guard !Task.isCancelled, revision == galleryRevision, let session else { return nil }
        let key = NSNumber(value: object.id)
        if let image = thumbnails.object(forKey: key) { return image }
        guard !thumbnailUnsupported, !missingThumbnails.contains(object.id) else { return nil }
        busy = true; loadingThumbnail = true
        return await Task { () -> UIImage? in
            defer { loadingThumbnail = false; finishOperation() }
            do {
                let data = try await session.getThumbnail(object.id)
                if let image = Self.decodeImage(CGImageSourceCreateWithData(data as CFData, nil), maxPixels: 240) {
                    thumbnails.setObject(image, forKey: key)
                    return image
                }
                missingThumbnails.insert(object.id)
            } catch PTPError.response(let code) {
                if code == ResponseCode.operationNotSupported.rawValue { thumbnailUnsupported = true }
                missingThumbnails.insert(object.id)
            } catch { await handleCameraError(error) }
            return nil
        }.value
    }

    func preview(for object: CameraObject) async throws -> UIImage? {
        if object.isRAW { return await thumbnail(for: object) }
        let generation = connectionGeneration
        while busy || authorizing { try await Task.sleep(for: .milliseconds(60)) }
        try Task.checkCancellation()
        guard generation == connectionGeneration, let session else { throw PTPError.disconnected }
        busy = true
        return try await Task { () -> UIImage? in
            defer { finishOperation() }
            let file = try TransferFile(filename: object.info.filename)
            do {
                try await session.getObject(object.id) { try await file.write($0) }
                try await file.finish()
                let image = Self.decodeImage(CGImageSourceCreateWithURL(file.url as CFURL, nil), maxPixels: 4096)
                await file.remove()
                return image
            } catch {
                await file.remove()
                if let ptp = error as? PTPError { await handleCameraError(ptp) }
                throw error
            }
        }.value
    }

    private static func decodeImage(_ source: CGImageSource?, maxPixels: Int) -> UIImage? {
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func refreshStatus() async {
        guard !isBackgrounded, !busy, let session else { return }
        busy = true
        let refresh = Task {
            defer { finishOperation() }
            trace.record("PTP keepalive: reading battery")
            do { try await readBattery(from: session) }
            catch { await connectionLost(error) }
        }
        statusRefresh = refresh
        await refresh.value
        statusRefresh = nil
    }

    private func readBattery(from camera: any CameraConnection) async throws {
        do { battery = try await camera.reportedBatteryLevel() }
        catch PTPError.response { battery = nil }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        let sleep = keepaliveSleep
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep() } catch { break }
                guard !Task.isCancelled, self?.session != nil else { break }
                await self?.refreshStatus()
            }
        }
    }

    private func handleCameraError(_ error: Error) async {
        if let ptp = error as? PTPError {
            if case .response = ptp {
                self.error = String(describing: ptp)
            } else {
                await connectionLost(ptp)
            }
        } else {
            self.error = error.localizedDescription
        }
    }

    private func connectionLost(_ error: Error) async {
        trace.record("PTP connection lost: \(Self.transportFailure(error))")
        let camera = session
        clearConnection()
        if resumeCamera == nil {
            self.error = "Connection lost: \(String(describing: error)). Check camera Wi-Fi and reconnect."
        }
        try? await camera?.close()
    }

    func saveSelected() async {
        await save(objects.filter { selected.contains($0.id) })
    }

    func savePhoto(_ object: CameraObject) async {
        await save(objects.filter { $0.id == object.id && !completed.contains($0.id) })
    }

    private func save(_ pending: [CameraObject]) async {
        guard !busy, !authorizing, session != nil else { return }
        guard !pending.isEmpty else { return }
        let generation = connectionGeneration
        authorizing = true
        error = nil
        do { try await importer.authorize() }
        catch {
            if generation == connectionGeneration { self.error = error.localizedDescription }
            authorizing = false
            return
        }
        if let statusRefresh { await statusRefresh.value }
        authorizing = false
        guard generation == connectionGeneration, !busy, let session else { return }
        busy = true; error = nil; transferSummary = nil
        defer { finishOperation() }
        fileProgress = [:]; overallProgress = 0
        let total = max(1, pending.reduce(UInt64(0)) { $0 + UInt64($1.info.size) })
        var savedBytes: UInt64 = 0
        var saved = 0
        do {
            for object in pending {
                let file = try TransferFile(filename: object.info.filename)
                do {
                    let priorBytes = savedBytes
                    try await session.getObject(object.id) { [weak self] chunk in
                        try await file.write(chunk)
                        await self?.advance(object: object, count: chunk.count, priorBytes: priorBytes, total: total)
                    }
                    try await file.finish()
                    do { try await importer.importPhoto(at: file.url, originalFilename: object.info.filename) }
                    catch {
                        throw ImportFailure(message: "\(object.info.filename): \(object.isRAW ? "RAW may not be supported by Photos on this device. " : "")\(error.localizedDescription)")
                    }
                    await file.remove()
                    savedBytes += UInt64(object.info.size); saved += 1
                    completed.insert(object.id)
                    selected.remove(object.id)
                } catch { await file.remove(); throw error }
            }
            overallProgress = 1
            transferSummary = "Saved \(saved) \(saved == 1 ? "photo" : "photos") to Camera Roll"
        } catch {
            await handleCameraError(error)
            if device != nil { transferSummary = "Saved \(saved) of \(pending.count) photos" }
        }
    }

    private func advance(object: CameraObject, count: Int, priorBytes: UInt64, total: UInt64) {
        let fraction = fileProgress[object.id, default: 0] + Double(count) / Double(max(1, object.info.size))
        fileProgress[object.id] = min(1, fraction)
        overallProgress = min(1, (Double(priorBytes) + fraction * Double(object.info.size)) / Double(total))
    }

    func disconnect() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { finishOperation() }
        let camera = session
        resumeCamera = nil
        clearConnection()
        do { try await camera?.close() } catch { self.error = String(describing: error) }
        pairing.releaseBluetooth()
    }

    private static func transportFailure(_ error: Error) -> String {
        if let ptp = error as? PTPError { return String(describing: ptp) }
        let failure = error as NSError
        return "\(failure.domain) (\(failure.code))"
    }

    private func clearConnection() {
        connectionGeneration += 1
        keepaliveTask?.cancel(); keepaliveTask = nil
        telemetryTask?.cancel(); telemetryTask = nil; session = nil
        connectedCamera = nil
        device = nil; battery = nil; storages = []; objects = []; selected = []
        galleryRevision += 1
        thumbnails.removeAllObjects(); missingThumbnails.removeAll(); thumbnailUnsupported = false
        completed = []; fileProgress = [:]; transferSummary = nil; overallProgress = 0
        telemetry = ConnectionTelemetry()
    }
}

struct ImportFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

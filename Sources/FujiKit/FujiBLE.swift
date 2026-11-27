import Foundation

public struct GATTCharacteristic: Hashable, Codable, Sendable {
    public let service: String
    public let uuid: String

    public init(service: String, uuid: String) {
        self.service = service.uppercased()
        self.uuid = uuid.uppercased()
    }
}

public enum FujiBLE {
    public enum Advertising {
        public static let companyID: UInt16 = 0x04D8
        public static let cameraRemote = "117C4142-EDD4-4C77-8696-DD18EEBB770A"
        public static let xApp = "AF854C2E-B214-458E-97E2-912C4ECF2CB8"
        public static let secure = "A9D2B304-E8D6-4902-8336-352B772D7597"
        public static let standby = "731893F9-744E-4899-B7E3-174106FF2B82"
    }

    public enum Pairing {
        public static let basicService = "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8"
        public static let secureService = "123D8F06-62A1-4935-9322-833C531EE225"
        public static let token = GATTCharacteristic(service: basicService, uuid: "ABA356EB-9633-4E60-B73F-F52516DBD671")
        public static let basicIdentity = GATTCharacteristic(service: basicService, uuid: "85B9163E-62D1-49FF-A6F5-054B4630D4A1")
        public static let secureIdentity = GATTCharacteristic(service: secureService, uuid: basicIdentity.uuid)
        public static let status = GATTCharacteristic(service: secureService, uuid: "F557D96B-8284-4667-8793-B971C1DECA2A")
        public static let unknown = GATTCharacteristic(service: secureService, uuid: "EB4166B0-9CCA-445E-A4E4-75B3817FD57A")
    }

    public enum Configuration {
        public static let service = "4C0020FE-F3B6-40DE-ACC9-77D129067B14"
        public static let indicator1 = GATTCharacteristic(service: service, uuid: "A68E3F66-0FCC-4395-8D4C-AA980B5877FA")
        public static let indicator2 = GATTCharacteristic(service: service, uuid: "BD17BA04-B76B-4892-A545-B73BA1F74DAE")
        public static let indicator3 = GATTCharacteristic(service: service, uuid: "049EC406-EF75-4205-A390-08FE209C51F0")
        public static let configured = GATTCharacteristic(service: service, uuid: "F9150137-5D40-4801-A8DC-F7FC5B01DA50")
        public static let geotagUpdate = GATTCharacteristic(service: service, uuid: "AD06C7B7-F41A-46F4-A29A-712055319122")
        public static let notification6 = GATTCharacteristic(service: service, uuid: "E6692C5C-B7CD-44F4-95FC-EDA07CE32560")
        public static let unknown = GATTCharacteristic(service: service, uuid: "1587B102-0B6D-4B63-9226-66FCC6D17387")
        public static let stateErrorDetails = unknown
        public static let subscriptions = [indicator1, indicator2, indicator3, configured, geotagUpdate]
    }

    public enum Information {
        public static let accessService = "00001800-0000-1000-8000-00805F9B34FB"
        public static let deviceService = "0000180A-0000-1000-8000-00805F9B34FB"
        public static let name = GATTCharacteristic(service: accessService, uuid: "00002A00-0000-1000-8000-00805F9B34FB")
        public static let serial = GATTCharacteristic(service: deviceService, uuid: "00002A25-0000-1000-8000-00805F9B34FB")
        public static let firmware = GATTCharacteristic(service: deviceService, uuid: "00002A26-0000-1000-8000-00805F9B34FB")
    }

    public enum LaunchFunction: UInt8, Sendable {
        case imageBrowsing = 3
        case remoteShooting = 4
    }

    public enum WiFi {
        public static let service = "4E941240-D01D-46B9-A5EA-67636806830B"
        public static let ssid = GATTCharacteristic(service: service, uuid: "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4")
        public static let password = GATTCharacteristic(service: service, uuid: "E809256A-915C-4967-92E8-53B7D4CAD213")
        public static let readiness = Configuration.indicator1
        public static let trigger = GATTCharacteristic(service: Control.service, uuid: "600655E6-3637-42F1-8FB2-44EFC5C63B13")
    }

    public enum Control {
        public static let service = "6514EB81-4E8F-458D-AA2A-E691336CDFAC"
        public static let shutter = GATTCharacteristic(service: service, uuid: "7FCF49C6-4FF0-4777-A03D-1A79166AF7A8")
        public static let status = GATTCharacteristic(service: service, uuid: "2674F0B0-F909-4E73-8656-338E9C74457F")
        public static let uploadBackup = GATTCharacteristic(service: service, uuid: "F1897EB9-A9AA-40F0-8CE6-2FA7915BC459")
        public static let readBackup = GATTCharacteristic(service: service, uuid: "F14E7A88-6F57-4872-A69B-B47EF3295C9B")
    }

    public enum Geotag {
        public static let service = "3B46EC2B-48BA-41FD-B1B8-ED860B60D22B"
        public static let location = GATTCharacteristic(service: service, uuid: "0F36EC14-29E5-411A-A1B6-64EE8383F090")
        public static let interval = GATTCharacteristic(service: WiFi.service, uuid: "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B")
        public static let time = GATTCharacteristic(service: "E872B11F-D526-4AE1-9BB4-89A99D48FA59", uuid: "B9BFD37F-CCAD-4D36-A1EE-018E792B3EDF")
        public static let timeUnknown = GATTCharacteristic(service: time.service, uuid: "C52EDBCE-1FE2-4ECC-9483-907E6592BE9E")
    }

    public enum Lens {
        public static let service = "15CA59FE-620C-464D-A987-223FAB660CDE"
        public static let name = GATTCharacteristic(service: service, uuid: "68887A7A-10A7-4A4A-AADD-6F9DB1ABAA0E")
        public static let firmware = GATTCharacteristic(service: service, uuid: "621A98D8-6314-4C3E-A683-EEA1D6166606")
    }

    public enum Files {
        public static let service = Advertising.xApp
        public static let info = GATTCharacteristic(service: service, uuid: "C922AC69-9480-4348-8F4B-9EE29BC30D1D")
        public static let chunkSize = GATTCharacteristic(service: service, uuid: "7F3400FE-17E7-4B80-8A0E-81B0343C1B49")
        public static let chunk = GATTCharacteristic(service: service, uuid: "AC0C799A-FA6C-4DF5-BBC5-BB95CCE7E6EA")
        public static let unknown1 = GATTCharacteristic(service: service, uuid: "E3FBBFCF-F326-4B0F-82CF-B00AE1B107A2")
        public static let unknown2 = GATTCharacteristic(service: service, uuid: "051DD980-DF9D-4472-A2E1-35811DD24EE1")
        public static let unknown6 = GATTCharacteristic(service: service, uuid: "68052E8A-FB91-404F-8847-0EB4BE24308C")
        public static let unknown7 = GATTCharacteristic(service: service, uuid: "2E27ED9F-5506-41CD-BA48-DAC06669AD95")
    }

    public enum Other {
        public static let notification3 = GATTCharacteristic(service: "804DAA8E-FFEB-4AB3-8E75-6EDD7303208D", uuid: "7170FD5A-56D9-4C19-B043-7A7047D8E1A0")
        public static let unknown0 = GATTCharacteristic(service: WiFi.service, uuid: "98934B2C-756C-4632-AA2F-DCBA1BFEC824")
        public static let notification5 = GATTCharacteristic(service: WiFi.service, uuid: "75823784-FBB7-4B71-ABAE-CD9A34072E3C")
        public static let notification7 = GATTCharacteristic(service: WiFi.service, uuid: "AAB609C4-94DD-4D89-BC60-665D5090B828")
        public static let notification8 = GATTCharacteristic(service: WiFi.service, uuid: "2A125640-706D-4DD1-B420-C0F4AB93C361")
        public static let notification10 = GATTCharacteristic(service: WiFi.service, uuid: "DEEF7187-3F43-4364-9E22-11A8C8A15951")
        public static let cameraRemoteUnknown = GATTCharacteristic(service: Advertising.cameraRemote, uuid: "49A12959-DFAA-4EB2-89CE-62548AD948F3")
    }

    public static func advertisement(manufacturerData: [UInt8], services: [String]) -> FujiBLEKind? {
        guard manufacturerData.count >= 3, manufacturerData[0...1] == [0xD8, 0x04] else { return nil }
        let services = Set(services.map { $0.uppercased() })
        if services.contains(Advertising.secure) {
            guard manufacturerData.count == 8 else { return nil }
            return .secure(serial: Array(manufacturerData[3..<8]))
        }
        guard manufacturerData.count == 7, manufacturerData[2] == 0x02,
            !services.isDisjoint(with: [Advertising.cameraRemote, Advertising.xApp])
        else { return nil }
        return .basic(token: Array(manufacturerData[3..<7]))
    }
}

public enum FujiBLEKind: Equatable, Codable, Sendable {
    case basic(token: [UInt8])
    case secure(serial: [UInt8])
}

public struct PairedCamera: Equatable, Codable, Sendable {
    public var peripheralIdentifier: String
    public var kind: FujiBLEKind
    public var name: String?
    public var ssid: String?

    public init(peripheralIdentifier: String, kind: FujiBLEKind, name: String? = nil, ssid: String? = nil) {
        self.peripheralIdentifier = peripheralIdentifier
        self.kind = kind
        self.name = name
        self.ssid = ssid
    }
}

public enum FujiBLEError: Error, Equatable, Sendable {
    case missingService(String)
    case missingCharacteristic(GATTCharacteristic)
    case badLength(expected: Int, actual: Int)
    case emptySSID
}

public struct GATTNotification: Sendable {
    public let characteristic: GATTCharacteristic
    public let value: [UInt8]

    public init(characteristic: GATTCharacteristic, value: [UInt8]) {
        self.characteristic = characteristic
        self.value = value
    }
}

public protocol GATTPeripheral: Sendable {
    func discover() async throws -> [String: Set<String>]
    func discover(service: String) async throws -> [String: Set<String>]
    func read(_ characteristic: GATTCharacteristic) async throws -> [UInt8]
    func write(_ value: [UInt8], to characteristic: GATTCharacteristic, withResponse: Bool) async throws
    func setNotify(_ enabled: Bool, for characteristic: GATTCharacteristic) async throws
    func notifications() async -> AsyncStream<GATTNotification>
}

public extension GATTPeripheral {
    func discover(service: String) async throws -> [String: Set<String>] {
        try await discover().filter { $0.key.uppercased() == service.uppercased() }
    }
}

public struct BLECameraInfo: Equatable, Sendable {
    public let name: String?
    public let serial: String?
    public let firmware: String?
}

public struct WiFiCredentials: Equatable, Sendable {
    public let ssid: String
    public let passphrase: String?
    public let readinessTimedOut: Bool
}

public struct FujiBLEDriver: Sendable {
    private let peripheral: any GATTPeripheral
    private let sleep: @Sendable (Duration) async throws -> Void
    private let trace: @Sendable (String) -> Void

    public init(
        peripheral: any GATTPeripheral,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        trace: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.peripheral = peripheral
        self.sleep = sleep
        self.trace = trace
    }

    public func pair(kind: FujiBLEKind, clientName: String) async throws {
        switch kind {
        case .basic(let token):
            let inventory = try await discover()
            try length(token, expected: 4)
            try require(FujiBLE.Pairing.token, in: inventory)
            try require(FujiBLE.Pairing.basicIdentity, in: inventory)
            try await write(token, to: FujiBLE.Pairing.token)
            try await write(Array(clientName.utf8) + [0], to: FujiBLE.Pairing.basicIdentity)
        case .secure(let serial):
            let inventory = try await discover(service: FujiBLE.Pairing.secureService)
            try length(serial, expected: 5)
            try require(FujiBLE.Pairing.status, in: inventory)
            try require(FujiBLE.Pairing.secureIdentity, in: inventory)
            let status = try await peripheral.read(FujiBLE.Pairing.status)
            try length(status, expected: 4)

            try await write(Array(status.prefix(3)) + [0x20], to: FujiBLE.Pairing.status)
            try await write(Array(clientName.utf8) + [0], to: FujiBLE.Pairing.secureIdentity)
            _ = try await discover()
        }
        for characteristic in FujiBLE.Configuration.subscriptions {
            try Task.checkCancellation()
            try? await peripheral.setNotify(true, for: characteristic)
        }
        try Task.checkCancellation()
    }

    public func cameraInfo() async throws -> BLECameraInfo {
        let name = try await optionalString(FujiBLE.Information.name)
        let serial = try await optionalString(FujiBLE.Information.serial)
        let firmware = try await optionalString(FujiBLE.Information.firmware)
        return BLECameraInfo(name: name, serial: serial, firmware: firmware)
    }

    public func handoff(function: FujiBLE.LaunchFunction = .remoteShooting, timeout: Duration = .seconds(10)) async throws -> WiFiCredentials {
        let inventory = try await discover()
        try require(FujiBLE.WiFi.ssid, in: inventory)
        try require(FujiBLE.WiFi.trigger, in: inventory)
        let ssid = string(try await peripheral.read(FujiBLE.WiFi.ssid))
        guard !ssid.isEmpty else { throw FujiBLEError.emptySSID }
        let password = try await optionalString(FujiBLE.WiFi.password)
        trace("Camera network credentials read (values omitted)")
        let notifications = await peripheral.notifications()
        if function == .imageBrowsing {
            try await peripheral.setNotify(true, for: FujiBLE.WiFi.readiness)
        } else {
            try? await peripheral.setNotify(true, for: FujiBLE.WiFi.readiness)
        }
        let canReadErrorDetail = inventory[FujiBLE.Configuration.service]?.contains(FujiBLE.Configuration.stateErrorDetails.uuid) == true
        try Task.checkCancellation()
        trace("Sending Wi-Fi launch \(Self.hex([function.rawValue, 0]))")
        try await write([function.rawValue, 0], to: FujiBLE.WiFi.trigger)
        trace("Wi-Fi launch write acknowledged")
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var retryPending = false
                while true {
                    try Task.checkCancellation()
                    let state = try? await peripheral.read(FujiBLE.WiFi.readiness)
                    if let state { trace("AP state read: \(Self.hex(state))") }
                    if let state, Self.accessPointIsReady(state) { return true }
                    guard function == .imageBrowsing else { break }

                    if state == [0, 0x80], canReadErrorDetail,
                       let detail = try? await peripheral.read(FujiBLE.Configuration.stateErrorDetails) {
                        trace("AP error detail: \(Self.hex(detail))")
                        if detail == [2, 0] {
                            if retryPending {
                                try Task.checkCancellation()
                                trace("Retrying gallery launch after camera busy")
                                try await write([function.rawValue, 0], to: FujiBLE.WiFi.trigger)
                                retryPending = false
                            } else {
                                retryPending = true
                                try await sleep(.milliseconds(200))
                            }
                            continue
                        }
                    }
                    retryPending = false
                    try await sleep(.milliseconds(500))
                }
                try await sleep(max(.zero, timeout))
                return false
            }
            group.addTask {
                for await notification in notifications {
                    try Task.checkCancellation()
                    if notification.characteristic == FujiBLE.WiFi.readiness {
                        trace("AP indication: \(Self.hex(notification.value))")
                        if Self.accessPointIsReady(notification.value) { return true }
                    }
                }
                try await sleep(max(.zero, timeout))
                return false
            }
            group.addTask {
                try await sleep(max(.zero, timeout))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        try Task.checkCancellation()
        trace(ready ? "Camera AP ready" : "Camera AP readiness timed out")
        return WiFiCredentials(ssid: ssid, passphrase: password, readinessTimedOut: !ready)
    }

    private static func hex(_ value: [UInt8]) -> String {
        value.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func accessPointIsReady(_ value: [UInt8]) -> Bool {
        value == [0x01, 0x80] || value == [0x01, 0x00]
    }

    private func discover(service: String? = nil) async throws -> [String: Set<String>] {
        let discovered: [String: Set<String>]
        if let service {
            discovered = try await peripheral.discover(service: service)
        } else {
            discovered = try await peripheral.discover()
        }
        var result: [String: Set<String>] = [:]
        for (service, characteristics) in discovered {
            result[service.uppercased(), default: []].formUnion(characteristics.map { $0.uppercased() })
        }
        return result
    }

    private func require(_ characteristic: GATTCharacteristic, in inventory: [String: Set<String>]) throws {
        guard let service = inventory[characteristic.service] else {
            throw FujiBLEError.missingService(characteristic.service)
        }
        guard service.contains(characteristic.uuid) else {
            throw FujiBLEError.missingCharacteristic(characteristic)
        }
    }

    private func length(_ bytes: [UInt8], expected: Int) throws {
        guard bytes.count == expected else { throw FujiBLEError.badLength(expected: expected, actual: bytes.count) }
    }

    private func write(_ bytes: [UInt8], to characteristic: GATTCharacteristic) async throws {
        try await peripheral.write(bytes, to: characteristic, withResponse: true)
    }

    private func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    private func optionalString(_ characteristic: GATTCharacteristic) async throws -> String? {
        do {
            let value = string(try await peripheral.read(characteristic))
            return value.isEmpty ? nil : value
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}

import Foundation
import XCTest
@testable import FujiKit

final class FujiBLETests: XCTestCase {
    func testAdvertisements() {
        let basic = [UInt8]([0xD8, 0x04, 0x02, 1, 2, 3, 4])
        XCTAssertEqual(FujiBLE.advertisement(manufacturerData: basic,
            services: [FujiBLE.Advertising.cameraRemote.lowercased()]), .basic(token: [1, 2, 3, 4]))
        XCTAssertEqual(FujiBLE.advertisement(manufacturerData: basic,
            services: [FujiBLE.Advertising.xApp]), .basic(token: [1, 2, 3, 4]))
        let secure: [UInt8] = [0xD8, 0x04, 0x99, 1, 2, 3, 4, 5]
        XCTAssertEqual(FujiBLE.advertisement(manufacturerData: secure,
            services: [FujiBLE.Advertising.xApp, FujiBLE.Advertising.secure]), .secure(serial: [1, 2, 3, 4, 5]))
        for bytes in [[], [0xD8], [0xD8, 0x04], [0, 0, 2, 1, 2, 3, 4], [0xD8, 4, 2, 1]] as [[UInt8]] {
            XCTAssertNil(FujiBLE.advertisement(manufacturerData: bytes, services: [FujiBLE.Advertising.xApp]))
        }
        XCTAssertNil(FujiBLE.advertisement(manufacturerData: basic, services: []))
        XCTAssertNil(FujiBLE.advertisement(manufacturerData: basic, services: [FujiBLE.Advertising.secure]))
        XCTAssertNil(FujiBLE.advertisement(manufacturerData: [0xD8, 4, 3, 1, 2, 3, 4], services: [FujiBLE.Advertising.xApp]))
    }

    func testBasicPairingAndBestEffortSubscriptions() async throws {
        let peripheral = FakeGATT()
        await peripheral.failNotifications()
        try await FujiBLEDriver(peripheral: peripheral).pair(kind: .basic(token: [9, 8, 7, 6]), clientName: "Phone")
        let writes = await peripheral.writes()
        XCTAssertEqual(writes, [
            .write(FujiBLE.Pairing.token, [9, 8, 7, 6], true),
            .write(FujiBLE.Pairing.basicIdentity, Array("Phone".utf8) + [0], true),
        ])
        let events = await peripheral.events
        XCTAssertEqual(events.filter { if case .notify = $0 { return true }; return false }.count, 5)
    }

    func testSecurePairingEchoesHeader() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.Pairing.status, bytes: [0xAB, 0xCD, 0xEF, 0x99])
        try await FujiBLEDriver(peripheral: peripheral).pair(kind: .secure(serial: [1, 2, 3, 4, 5]), clientName: "iPhone")
        let events = await peripheral.events
        XCTAssertEqual(Array(events.prefix(5)), [
            .discoverService(FujiBLE.Pairing.secureService), .read(FujiBLE.Pairing.status),
            .write(FujiBLE.Pairing.status, [0xAB, 0xCD, 0xEF, 0x20], true),
            .write(FujiBLE.Pairing.secureIdentity, Array("iPhone".utf8) + [0], true),
            .discover,
        ])
    }

    func testBadLengths() async throws {
        let peripheral = FakeGATT()
        let driver = FujiBLEDriver(peripheral: peripheral)
        for (kind, expected, actual) in [(FujiBLEKind.basic(token: []), 4, 0), (.secure(serial: [1]), 5, 1)] {
            do {
                try await driver.pair(kind: kind, clientName: "Phone")
                XCTFail("Accepted invalid identifier")
            } catch {
                XCTAssertEqual(error as? FujiBLEError, .badLength(expected: expected, actual: actual))
            }
        }
        for bytes in [[], [1, 2, 3], [1, 2, 3, 4, 5]] as [[UInt8]] {
            await peripheral.script(FujiBLE.Pairing.status, bytes: bytes)
            do {
                try await driver.pair(kind: .secure(serial: [1, 2, 3, 4, 5]), clientName: "Phone")
                XCTFail("Accepted invalid status")
            } catch {
                XCTAssertEqual(error as? FujiBLEError, .badLength(expected: 4, actual: bytes.count))
            }
        }
    }

    func testMissingServiceAndCharacteristic() async throws {
        for missingService in [true, false] {
            let peripheral = FakeGATT()
            await peripheral.remove(FujiBLE.Pairing.token, service: missingService)
            do {
                try await FujiBLEDriver(peripheral: peripheral).pair(kind: .basic(token: [1, 2, 3, 4]), clientName: "Phone")
                XCTFail("Accepted missing GATT attribute")
            } catch {
                XCTAssertEqual(error as? FujiBLEError, missingService
                    ? .missingService(FujiBLE.Pairing.basicService) : .missingCharacteristic(FujiBLE.Pairing.token))
            }
            let writes = await peripheral.writes()
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testPairWriteFailurePropagates() async throws {
        let peripheral = FakeGATT()
        await peripheral.failWrites()
        do {
            try await FujiBLEDriver(peripheral: peripheral).pair(kind: .basic(token: [1, 2, 3, 4]), clientName: "Phone")
            XCTFail("Ignored write error")
        } catch {
            XCTAssertEqual(error as? PTPError, .disconnected)
        }
        let writes = await peripheral.writes()
        XCTAssertEqual(writes.count, 1)
    }

    func testCameraInfoBestEffort() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.Information.name, bytes: Array("Camera".utf8) + [0, 88])
        await peripheral.script(FujiBLE.Information.serial, bytes: [])
        let info = try await FujiBLEDriver(peripheral: peripheral).cameraInfo()
        XCTAssertEqual(info.name, "Camera")
        XCTAssertNil(info.serial)
        XCTAssertNil(info.firmware)
        await peripheral.script(FujiBLE.Information.serial, bytes: Array("1234".utf8))
        await peripheral.script(FujiBLE.Information.firmware, bytes: Array("1.10".utf8))
        let full = try await FujiBLEDriver(peripheral: peripheral).cameraInfo()
        XCTAssertEqual(full.serial, "1234")
        XCTAssertEqual(full.firmware, "1.10")
    }

    func testFullHandoffOrderAndReadinessRead() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.WiFi.password, bytes: Array("secret123".utf8))
        await peripheral.script(FujiBLE.Configuration.indicator1, bytes: [0x01, 0x80])
        let credentials = try await driver(peripheral).handoff()
        XCTAssertEqual(credentials.ssid, "FUJIFILM-Camera")
        XCTAssertEqual(credentials.passphrase, "secret123")
        XCTAssertFalse(credentials.readinessTimedOut)
        let events = await peripheral.events
        XCTAssertEqual(Array(events.prefix(6)), [
            .discover, .read(FujiBLE.WiFi.ssid), .read(FujiBLE.WiFi.password),
            .notify(FujiBLE.Configuration.indicator1),
            .write(FujiBLE.WiFi.trigger, [0x04, 0x00], true),
            .read(FujiBLE.Configuration.indicator1),
        ])
    }

    func testGalleryRetriesOnlyForTransientCameraBusy() async throws {
        for detail: UInt8 in [0, 2, 6] {
            let peripheral = FakeGATT()
            await peripheral.script(FujiBLE.WiFi.readiness, bytes: [0, 0x80])
            await peripheral.script(FujiBLE.Configuration.stateErrorDetails, bytes: [detail, 0])
            let credentials = try await FujiBLEDriver(peripheral: peripheral).handoff(function: .imageBrowsing, timeout: .seconds(1))
            XCTAssertTrue(credentials.readinessTimedOut)
            let writes = await peripheral.writes()
            XCTAssertTrue(writes.allSatisfy { $0 == .write(FujiBLE.WiFi.trigger, [3, 0], true) })
            if detail == 2 {
                XCTAssertGreaterThan(writes.count, 2)
            } else {
                XCTAssertEqual(writes.count, 1)
            }
        }
    }

    func testGalleryRecoversOnThirdLaunchAfterRepeatedBusy() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.WiFi.readiness, bytes: [0, 0x80])
        await peripheral.script(FujiBLE.Configuration.stateErrorDetails, bytes: [2, 0])
        await peripheral.becomeReady(onLaunch: 3)
        let credentials = try await FujiBLEDriver(peripheral: peripheral)
            .handoff(function: .imageBrowsing, timeout: .seconds(2))
        XCTAssertFalse(credentials.readinessTimedOut)
        let writes = await peripheral.writes()
        XCTAssertEqual(writes.count, 3)
    }

    func testGalleryDoesNotRelaunchWhenBusyClearsDuringBackoff() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.WiFi.readiness, bytes: [0, 0x80])
        await peripheral.script(FujiBLE.Configuration.stateErrorDetails, bytes: [2, 0])
        let driver = FujiBLEDriver(peripheral: peripheral, sleep: { duration in
            switch duration {
            case .milliseconds(200):
                await peripheral.script(FujiBLE.WiFi.readiness, bytes: [2, 0x80])
            case .milliseconds(500):
                await peripheral.script(FujiBLE.WiFi.readiness, bytes: [1, 0x80])
            default:
                try await Task.sleep(for: duration)
            }
        })
        let credentials = try await driver.handoff(function: .imageBrowsing)
        XCTAssertFalse(credentials.readinessTimedOut)
        let writes = await peripheral.writes()
        XCTAssertEqual(writes.count, 1)
    }

    func testIndicatorReadinessWithAbsentPassword() async throws {
        let peripheral = FakeGATT()
        await peripheral.emitOnTrigger([
            GATTNotification(characteristic: FujiBLE.Configuration.indicator2, value: [1, 0]),
            GATTNotification(characteristic: FujiBLE.Configuration.indicator1, value: [2, 0]),
            GATTNotification(characteristic: FujiBLE.Configuration.indicator1, value: [1, 0]),
        ])
        await peripheral.blockReadiness()
        let credentials = try await driver(peripheral).handoff()
        XCTAssertNil(credentials.passphrase)
        XCTAssertFalse(credentials.readinessTimedOut)
    }

    func testTimeoutProceedsWithCredentials() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.WiFi.readiness, bytes: [0])
        await peripheral.script(FujiBLE.WiFi.password, bytes: [])
        let credentials = try await driver(peripheral).handoff(timeout: .zero)
        XCTAssertEqual(credentials.ssid, "FUJIFILM-Camera")
        XCTAssertNil(credentials.passphrase)
        XCTAssertTrue(credentials.readinessTimedOut)
    }

    func testHandoffRecognizesXAppReadyNotification() async throws {
        let peripheral = FakeGATT()
        await peripheral.blockReadiness()
        await peripheral.emitOnTrigger([
            GATTNotification(characteristic: FujiBLE.Configuration.indicator1, value: [0x01, 0x80]),
        ])
        let credentials = try await driver(peripheral).handoff()
        XCTAssertFalse(credentials.readinessTimedOut)
    }

    func testHandoffIgnoresLaunchingStateAndImageResizeSetting() async throws {
        let peripheral = FakeGATT()
        let imageResizeSetting = GATTCharacteristic(
            service: FujiBLE.WiFi.service, uuid: "82A9F452-C5CE-4EF5-8203-3FC9A47F8171"
        )
        await peripheral.script(imageResizeSetting, bytes: [1])
        await peripheral.script(FujiBLE.Configuration.indicator1, bytes: [0x02, 0x80])
        await peripheral.emitOnTrigger([
            GATTNotification(characteristic: FujiBLE.Configuration.indicator1, value: [0x02, 0x80]),
        ])
        let credentials = try await driver(peripheral).handoff()
        XCTAssertTrue(credentials.readinessTimedOut)
    }

    func testEmptySSIDAndMissingTrigger() async throws {
        let peripheral = FakeGATT()
        await peripheral.script(FujiBLE.WiFi.ssid, bytes: [])
        do {
            _ = try await driver(peripheral).handoff()
            XCTFail("Accepted empty SSID")
        } catch {
            XCTAssertEqual(error as? FujiBLEError, .emptySSID)
        }
        await peripheral.remove(FujiBLE.WiFi.trigger, service: false)
        do {
            _ = try await driver(peripheral).handoff()
            XCTFail("Accepted missing trigger")
        } catch {
            XCTAssertEqual(error as? FujiBLEError, .missingCharacteristic(FujiBLE.WiFi.trigger))
        }
        let writes = await peripheral.writes()
        XCTAssertTrue(writes.isEmpty)
    }

    func testHandoffReadAndWriteErrorsPropagate() async throws {
        let peripheral = FakeGATT()
        await peripheral.removeRead(FujiBLE.WiFi.ssid)
        do {
            _ = try await driver(peripheral).handoff()
            XCTFail("Ignored SSID read failure")
        } catch {
            XCTAssertEqual(error as? PTPError, .disconnected)
        }
        await peripheral.script(FujiBLE.WiFi.ssid, bytes: [65])
        await peripheral.failWrites()
        do {
            _ = try await driver(peripheral).handoff()
            XCTFail("Ignored trigger failure")
        } catch {
            XCTAssertEqual(error as? PTPError, .disconnected)
        }
    }

    func testCancellationIsNotTimeout() async throws {
        let peripheral = FakeGATT()
        let task = Task {
            try Task.checkCancellation()
            return try await driver(peripheral).handoff()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Ignored cancellation")
        } catch is CancellationError {
        }
    }

    func testPairedCameraCodable() throws {
        for kind in [FujiBLEKind.basic(token: [1, 2, 3, 4]), .secure(serial: [1, 2, 3, 4, 5])] {
            let record = PairedCamera(peripheralIdentifier: UUID().uuidString, kind: kind, name: "Camera", ssid: "SSID")
            XCTAssertEqual(try JSONDecoder().decode(PairedCamera.self, from: JSONEncoder().encode(record)), record)
        }
        let minimal = PairedCamera(peripheralIdentifier: UUID().uuidString, kind: .basic(token: [0, 0, 0, 0]))
        XCTAssertEqual(try JSONDecoder().decode(PairedCamera.self, from: JSONEncoder().encode(minimal)), minimal)
    }

    private func driver(_ peripheral: FakeGATT) -> FujiBLEDriver {
        FujiBLEDriver(peripheral: peripheral, sleep: { duration in
            try await Task.sleep(for: duration == .zero ? .zero : .milliseconds(50))
        })
    }
}

private actor FakeGATT: GATTPeripheral {
    enum Event: Equatable {
        case discover
        case discoverService(String)
        case read(GATTCharacteristic)
        case write(GATTCharacteristic, [UInt8], Bool)
        case notify(GATTCharacteristic)
    }

    var events: [Event] = []
    private var inventory: [String: Set<String>] = [:]
    private var reads: [GATTCharacteristic: [UInt8]] = [FujiBLE.WiFi.ssid: Array("FUJIFILM-Camera".utf8)]
    private var notifyFails = false
    private var writeFails = false
    private var readinessBlocks = false
    private var launchesUntilReady: Int?
    private var triggerNotifications: [GATTNotification] = []
    private let stream: AsyncStream<GATTNotification>
    private let continuation: AsyncStream<GATTNotification>.Continuation

    init() {
        let pair = AsyncStream<GATTNotification>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        for characteristic in [FujiBLE.Pairing.token, FujiBLE.Pairing.basicIdentity,
            FujiBLE.Pairing.status, FujiBLE.Pairing.secureIdentity, FujiBLE.WiFi.ssid,
            FujiBLE.WiFi.password, FujiBLE.WiFi.trigger, FujiBLE.Configuration.stateErrorDetails] {
            inventory[characteristic.service, default: []].insert(characteristic.uuid)
        }
    }

    func discover() async throws -> [String: Set<String>] {
        events.append(.discover)
        return inventory
    }

    func discover(service: String) async throws -> [String: Set<String>] {
        events.append(.discoverService(service))
        return inventory.filter { $0.key == service }
    }

    func read(_ characteristic: GATTCharacteristic) async throws -> [UInt8] {
        events.append(.read(characteristic))
        if characteristic == FujiBLE.WiFi.readiness, readinessBlocks {
            try await Task.sleep(for: .seconds(100))
        }
        guard let value = reads[characteristic] else { throw PTPError.disconnected }
        return value
    }

    func write(_ value: [UInt8], to characteristic: GATTCharacteristic, withResponse: Bool) async throws {
        events.append(.write(characteristic, value, withResponse))
        if writeFails { throw PTPError.disconnected }
        if characteristic == FujiBLE.WiFi.trigger {
            if let remaining = launchesUntilReady {
                launchesUntilReady = remaining - 1
                if remaining == 1 { reads[FujiBLE.WiFi.readiness] = [1, 0x80] }
            }
            for notification in triggerNotifications { continuation.yield(notification) }
        }
    }

    func setNotify(_ enabled: Bool, for characteristic: GATTCharacteristic) async throws {
        events.append(.notify(characteristic))
        if notifyFails { throw PTPError.disconnected }
    }

    func notifications() async -> AsyncStream<GATTNotification> { stream }
    func script(_ characteristic: GATTCharacteristic, bytes: [UInt8]) { reads[characteristic] = bytes }
    func removeRead(_ characteristic: GATTCharacteristic) { reads[characteristic] = nil }
    func failNotifications() { notifyFails = true }
    func failWrites() { writeFails = true }
    func becomeReady(onLaunch count: Int) { launchesUntilReady = count }
    func blockReadiness() { readinessBlocks = true }
    func emitOnTrigger(_ notifications: [GATTNotification]) { triggerNotifications = notifications }
    func remove(_ characteristic: GATTCharacteristic, service: Bool) {
        if service { inventory[characteristic.service] = nil }
        else { inventory[characteristic.service]?.remove(characteristic.uuid) }
    }
    func writes() -> [Event] { events.filter { if case .write = $0 { return true }; return false } }
}

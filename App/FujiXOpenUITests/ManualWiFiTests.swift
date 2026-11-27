import XCTest

final class ManualWiFiTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

#if DEBUG && targetEnvironment(simulator) && !HOTSPOT_AUTOJOIN
    @MainActor
    func testPairingPromptsForManualWiFiAndContinues() {
        let app = XCUIApplication()
        app.launchArguments = ["-test-manual-camera-wifi"]
        app.launch()

        let title = app.staticTexts["Fuji Kit"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        assertCentered(title, in: app)
        assertCentered(app.buttons["Pair a camera"], in: app)
        openPairing(in: app)
        let camera = app.buttons["X-T30 III"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        assertCentered(camera, in: app)
        camera.tap()

        XCTAssertTrue(app.navigationBars["Join camera Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The gallery opens automatically when connected."].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "FUJIFILM-X-T30-III")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "camera-password")).firstMatch.exists)
        XCTAssertFalse(app.navigationBars["Photos"].exists)

        let copySSID = app.buttons["Copy SSID"]
        XCTAssertTrue(copySSID.exists)
        copySSID.tap()
        XCTAssertTrue(app.buttons["Copy password"].exists)

        let joined = app.buttons["I’ve joined"]
        assertCentered(joined, in: app)
        joined.tap()
        XCTAssertTrue(app.navigationBars["Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Preview DSCF0001.JPG"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAlreadyJoinedOpensGalleryAutomatically() {
        let app = XCUIApplication()
        app.launchArguments = ["-test-manual-camera-wifi", "-test-already-joined"]
        app.launch()
        openPairing(in: app)
        let camera = app.buttons["X-T30 III"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        XCTAssertTrue(app.navigationBars["Join camera Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Preview DSCF0001.JPG"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNearbyCamerasShowOneEntryPerCameraAndClearWhenItStops() {
        let app = XCUIApplication()
        app.launchArguments = ["-test-nearby-camera-churn"]
        app.launch()

        openPairing(in: app)
        let cameras = app.buttons.matching(identifier: "X-T30 III")
        XCTAssertTrue(cameras.firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            XCTAssertEqual(cameras.count, 1)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(cameras.firstMatch.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Leave the camera’s pairing screen open. Make sure it isn’t connected to another phone."].exists)
    }

    @MainActor
    func testGalleryPreviewSaveAndReconnect() {
        let app = XCUIApplication()
        app.launchArguments = ["-test-manual-camera-wifi"]
        app.launch()

        openPairing(in: app)
        app.buttons["X-T30 III"].tap()
        let joined = app.buttons["I’ve joined"]
        XCTAssertTrue(joined.waitForExistence(timeout: 5))
        joined.tap()

        let preview = app.buttons["Preview DSCF0001.JPG"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        XCTAssertTrue(app.navigationBars["DSCF0001.JPG"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let select = app.buttons["Select DSCF0001.JPG"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let save = app.buttons["Save to Photos (1)"]
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved 1 photo to Camera Roll"].waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))

        let options = app.buttons["Camera options"]
        options.tap()
        app.buttons["Camera details"].tap()
        XCTAssertTrue(app.navigationBars["Camera details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Throughput"].exists)
        app.buttons["Done"].tap()

        options.tap()
        app.buttons["Disconnect"].tap()
        let reconnect = app.buttons["Connect to X-T30 III"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        XCTAssertTrue(joined.waitForExistence(timeout: 5))
        joined.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
    }

    @MainActor
    func testManualConnectionIsAvailableFromConnectionOptions() {
        let app = XCUIApplication()
        app.launchArguments = ["-test-manual-camera-wifi"]
        app.launch()

        XCTAssertFalse(app.buttons["Open gallery on camera Wi-Fi"].exists)
        XCTAssertFalse(app.textFields["Camera host"].exists)
        app.buttons["Connection options"].tap()
        XCTAssertTrue(app.buttons["Open gallery on camera Wi-Fi"].exists)
        app.buttons["Connect manually over Wi-Fi"].tap()
        XCTAssertTrue(app.navigationBars["Connect over Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Camera host"].exists)
        XCTAssertTrue(app.textFields["Camera port"].exists)
        XCTAssertTrue(app.buttons["Find camera"].exists)
    }

    @MainActor
    private func assertCentered(_ element: XCUIElement, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertEqual(element.frame.midX, app.frame.midX, accuracy: 8, file: file, line: line)
        XCTAssertGreaterThan(element.frame.midY, app.frame.height * 0.30 + app.frame.minY, file: file, line: line)
    }

    @MainActor
    private func openPairing(in app: XCUIApplication) {
        let pairing = app.buttons["Pair a camera"]
        XCTAssertTrue(pairing.waitForExistence(timeout: 5))
        pairing.tap()
        XCTAssertTrue(app.navigationBars["Pair a camera"].waitForExistence(timeout: 5))
    }
#endif
}

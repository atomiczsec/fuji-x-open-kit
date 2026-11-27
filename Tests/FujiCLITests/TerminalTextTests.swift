import XCTest
@testable import fujictl

final class TerminalTextTests: XCTestCase {
    func testPrintableAndEmptyText() {
        XCTAssertEqual(TerminalText.escaped("富士 X-T5"), "富士 X-T5")
        XCTAssertEqual(TerminalText.escaped(""), "")
    }

    func testUntrustedControlCharacters() {
        XCTAssertEqual(
            TerminalText.escaped("\u{1b}[2J\n\r\t\u{7}\u{9b}\u{202e}"),
            "\\u{1b}[2J\\u{a}\\u{d}\\u{9}\\u{7}\\u{9b}\\u{202e}")
    }
}

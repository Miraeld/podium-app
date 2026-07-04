import XCTest
@testable import PodiumServer

/// Unit coverage for `RequestDecoding.swift`'s shared helpers — no HTTP
/// server needed since these are pure functions.
final class RequestDecodingTests: XCTestCase {
    // MARK: - Bug 2: jsParseInt mirrors JS `parseInt(raw, 10)` leniency

    /// Node's routers (sessions.js, events.js, stats.js, analytics.js,
    /// pricing.js, agents.js) all use `parseInt(req.query.X, 10)` /
    /// `parseInt(req.query.X)`, which parses a leading run of digits and
    /// ignores trailing garbage — stricter than Swift's `Int.init(_:)`.
    func testJsParseIntConsumesLeadingDigitsAndIgnoresTrailingGarbage() {
        XCTAssertEqual(jsParseInt("50abc"), 50)
        XCTAssertEqual(jsParseInt("123xyz456"), 123)
    }

    func testJsParseIntStripsLeadingWhitespace() {
        XCTAssertEqual(jsParseInt("  50"), 50)
        XCTAssertEqual(jsParseInt("\t\n 7"), 7)
    }

    func testJsParseIntAcceptsLeadingPlusSign() {
        XCTAssertEqual(jsParseInt("+5"), 5)
    }

    func testJsParseIntAcceptsLeadingMinusSign() {
        XCTAssertEqual(jsParseInt("-5"), -5)
        XCTAssertEqual(jsParseInt("-5abc"), -5)
    }

    func testJsParseIntReturnsNilForEmptyString() {
        XCTAssertNil(jsParseInt(""))
    }

    func testJsParseIntReturnsNilWhenNoLeadingDigits() {
        XCTAssertNil(jsParseInt("abc"))
        XCTAssertNil(jsParseInt("   "))
        XCTAssertNil(jsParseInt("+"))
        XCTAssertNil(jsParseInt("-"))
    }

    func testJsParseIntPlainIntegerStillWorks() {
        XCTAssertEqual(jsParseInt("50"), 50)
        XCTAssertEqual(jsParseInt("0"), 0)
    }

    // MARK: - Bug 5: collapseEmpty mirrors JS `field || null`

    func testCollapseEmptyTurnsEmptyStringIntoNil() {
        XCTAssertNil(collapseEmpty(""))
    }

    func testCollapseEmptyPassesThroughNonEmptyString() {
        XCTAssertEqual(collapseEmpty("hello"), "hello")
    }

    func testCollapseEmptyPassesThroughNil() {
        XCTAssertNil(collapseEmpty(nil))
    }
}

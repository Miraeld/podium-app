import XCTest
@testable import PodiumServer

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(PodiumServerInfo.placeholder)
    }
}

import XCTest
@testable import PodiumCore

final class PlaceholderTests: XCTestCase {
    func testSQLiteLinks() {
        XCTAssertFalse(podiumCoreSQLiteVersion().isEmpty)
    }
}

import XCTest
@testable import PodiumCore

final class BashOutputParsersTests: XCTestCase {

    // MARK: - PHPUnit

    func testParsePhpUnitOkForm() {
        let result = BashOutputParsers.parsePhpUnit("OK (47 tests, 123 assertions)")
        XCTAssertEqual(result?.tests, 47)
        XCTAssertEqual(result?.assertions, 123)
        XCTAssertEqual(result?.failures, 0)
        XCTAssertEqual(result?.errors, 0)
        XCTAssertTrue(result?.passed ?? false)
    }

    func testParsePhpUnitSummaryFormWithFailures() {
        let result = BashOutputParsers.parsePhpUnit("Tests: 47, Assertions: 123, Failures: 2, Errors: 1")
        XCTAssertEqual(result?.tests, 47)
        XCTAssertEqual(result?.assertions, 123)
        XCTAssertEqual(result?.failures, 2)
        XCTAssertEqual(result?.errors, 1)
        XCTAssertFalse(result?.passed ?? true)
    }

    func testParsePhpUnitReturnsNilForUnrelatedOutput() {
        XCTAssertNil(BashOutputParsers.parsePhpUnit("just some random bash output"))
        XCTAssertNil(BashOutputParsers.parsePhpUnit(nil))
        XCTAssertNil(BashOutputParsers.parsePhpUnit(""))
    }

    // MARK: - PHPCS

    func testParsePhpcsErrorsAndWarnings() {
        let result = BashOutputParsers.parsePhpcs("FOUND 3 ERRORS AND 2 WARNINGS AFFECTING 4 LINES")
        XCTAssertEqual(result?.errors, 3)
        XCTAssertEqual(result?.warnings, 2)
    }

    func testParsePhpcsErrorsOnly() {
        let result = BashOutputParsers.parsePhpcs("FOUND 3 ERRORS AFFECTING 4 LINES")
        XCTAssertEqual(result?.errors, 3)
        XCTAssertEqual(result?.warnings, 0)
    }

    func testParsePhpcsNoErrors() {
        let result = BashOutputParsers.parsePhpcs("No errors detected")
        XCTAssertEqual(result?.errors, 0)
        XCTAssertEqual(result?.warnings, 0)
    }

    // MARK: - PR URL

    func testExtractPrUrlFindsFirstMatch() {
        let output = "Some output\nCreated pull request: https://github.com/acme/widgets/pull/42\nmore text https://github.com/acme/widgets/pull/99"
        XCTAssertEqual(BashOutputParsers.extractPrUrl(output), "https://github.com/acme/widgets/pull/42")
    }

    func testExtractPrUrlReturnsNilWhenAbsent() {
        XCTAssertNil(BashOutputParsers.extractPrUrl("no url here"))
    }

    // MARK: - git diff --stat

    func testParseGitStatFullForm() {
        let result = BashOutputParsers.parseGitStat("3 files changed, 20 insertions(+), 5 deletions(-)")
        XCTAssertEqual(result?.filesChanged, 3)
        XCTAssertEqual(result?.insertions, 20)
        XCTAssertEqual(result?.deletions, 5)
    }

    func testParseGitStatInsertionsOnly() {
        let result = BashOutputParsers.parseGitStat("1 file changed, 10 insertions(+)")
        XCTAssertEqual(result?.filesChanged, 1)
        XCTAssertEqual(result?.insertions, 10)
        XCTAssertEqual(result?.deletions, 0)
    }
}

final class NotificationClassifierTests: XCTestCase {
    func testPermissionPromptIsWaitingForUser() {
        XCTAssertTrue(NotificationClassifier.isWaitingForUser("Claude needs your permission to run this command"))
    }

    func testExplicitWaitingForInputIsWaitingForUser() {
        XCTAssertTrue(NotificationClassifier.isWaitingForUser("Claude is waiting for your input"))
        XCTAssertTrue(NotificationClassifier.isWaitingForUser("Approval required before continuing"))
        XCTAssertTrue(NotificationClassifier.isWaitingForUser("Awaiting your response"))
    }

    func testIdleNotificationIsNotWaitingForUser() {
        XCTAssertFalse(NotificationClassifier.isWaitingForUser("Claude has finished responding"))
        XCTAssertFalse(NotificationClassifier.isWaitingForUser(nil))
        XCTAssertFalse(NotificationClassifier.isWaitingForUser(""))
    }

    func testCompactionMessageDetected() {
        XCTAssertTrue(NotificationClassifier.isCompactionRelated("Compacting conversation history"))
        XCTAssertTrue(NotificationClassifier.isCompactionRelated("Context is being reduced to fit"))
        XCTAssertFalse(NotificationClassifier.isCompactionRelated("Claude has finished responding"))
    }
}

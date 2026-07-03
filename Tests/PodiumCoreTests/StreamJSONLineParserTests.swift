import XCTest
@testable import PodiumCore

final class StreamJSONLineParserTests: XCTestCase {
    func testPushParsesACompleteLine() {
        var parser = StreamJSONLineParser()
        let results = parser.push("{\"type\":\"system\"}\n")
        XCTAssertEqual(results.count, 1)
        guard case .success(let value) = results[0] else { return XCTFail("expected success") }
        XCTAssertEqual(value.objectValue?["type"]?.stringValue, "system")
    }

    func testPushReassemblesALineSplitAcrossChunks() {
        var parser = StreamJSONLineParser()
        XCTAssertTrue(parser.push("{\"type\":\"sys").isEmpty)
        let results = parser.push("tem\"}\n")
        XCTAssertEqual(results.count, 1)
        guard case .success(let value) = results[0] else { return XCTFail("expected success") }
        XCTAssertEqual(value.objectValue?["type"]?.stringValue, "system")
    }

    func testPushHandlesMultipleLinesInOneChunk() {
        var parser = StreamJSONLineParser()
        let results = parser.push("{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
        XCTAssertEqual(results.count, 3)
        for (idx, result) in results.enumerated() {
            guard case .success(let value) = result else { return XCTFail("expected success") }
            XCTAssertEqual(value.objectValue?["n"]?.stringValue, nil) // number, not string
            if case .number(let n)? = value.objectValue?["n"] {
                XCTAssertEqual(n, Double(idx + 1))
            } else {
                XCTFail("expected number")
            }
        }
    }

    func testBlankLinesAreSkipped() {
        var parser = StreamJSONLineParser()
        let results = parser.push("\n\n{\"a\":1}\n\n")
        XCTAssertEqual(results.count, 1)
    }

    func testMalformedLineReportsFailureWithoutThrowing() {
        var parser = StreamJSONLineParser()
        let results = parser.push("not json at all\n")
        XCTAssertEqual(results.count, 1)
        guard case .failure(let err) = results[0] else { return XCTFail("expected failure") }
        XCTAssertEqual(err.raw, "not json at all")
    }

    func testFlushEmitsTrailingPartialLine() {
        var parser = StreamJSONLineParser()
        XCTAssertTrue(parser.push("{\"tail\":true}").isEmpty)
        guard let result = parser.flush() else { return XCTFail("expected a flushed result") }
        guard case .success(let value) = result else { return XCTFail("expected success") }
        XCTAssertEqual(value.objectValue?["tail"], .bool(true))
    }

    func testFlushWithEmptyBufferReturnsNil() {
        var parser = StreamJSONLineParser()
        _ = parser.push("{\"a\":1}\n")
        XCTAssertNil(parser.flush())
    }
}

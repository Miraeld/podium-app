import XCTest
@testable import PodiumCore

/// Coverage of `ClaudeHome` (port of dashboard/server/lib/claude-home.js):
/// path resolution order, cwd encoding, scan fallbacks, compaction-agent
/// fuzzy matching, and the `setClaudeHome` persistence/validation contract.
final class ClaudeHomeTests: XCTestCase {
    private var tempHome: URL!
    private var tempDataDir: URL!
    private var originalClaudeEnv: [String: String]!
    private var originalPathsEnv: [String: String]!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-claude-home-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        tempDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-claude-home-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        originalPathsEnv = PodiumPaths.environment
        ClaudeHome.environment = ["CLAUDE_HOME": tempHome.path]
        PodiumPaths.environment = ["DASHBOARD_DATA_DIR": tempDataDir.path]
        ClaudeHome.resetOverrideCacheForTesting()
    }

    override func tearDownWithError() throws {
        ClaudeHome.environment = originalClaudeEnv
        PodiumPaths.environment = originalPathsEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempHome)
        try? FileManager.default.removeItem(at: tempDataDir)
    }

    // MARK: - encodeCwd

    func testEncodeCwdReplacesNonAlphanumericWithDash() {
        XCTAssertEqual(ClaudeHome.encodeCwd("/Users/txj/.codefuse"), "-Users-txj--codefuse")
        XCTAssertEqual(ClaudeHome.encodeCwd("/a/b_c 123"), "-a-b-c-123")
    }

    // MARK: - current()

    func testCurrentPrefersEnvOverride() {
        XCTAssertEqual(ClaudeHome.current(), tempHome.path)
    }

    func testCurrentFallsBackToDotClaudeWhenNoEnv() {
        ClaudeHome.environment = [:]
        let expected = PodiumPaths.homeDirectory().appendingPathComponent(".claude", isDirectory: true).path
        XCTAssertEqual(ClaudeHome.current(), expected)
    }

    // MARK: - transcriptPath / findTranscriptPath

    func testTranscriptPathResolvesDirectEncodedPath() throws {
        let cwd = "/Users/gael/project"
        let encoded = ClaudeHome.encodeCwd(cwd)
        let projectDir = tempHome.appendingPathComponent("projects").appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let transcript = projectDir.appendingPathComponent("sess-1.jsonl")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)

        let resolved = ClaudeHome.transcriptPath(sessionId: "sess-1", cwd: cwd)
        XCTAssertEqual(resolved, transcript.path)
    }

    func testTranscriptPathFallsBackToScanWhenEncodedCwdIsStale() throws {
        // The session's cwd changed since the transcript was written (or the
        // caller doesn't know it) — the file lives under a DIFFERENT
        // encoded-cwd directory than the one derived from `cwd`.
        let realDir = tempHome.appendingPathComponent("projects").appendingPathComponent("-some-other-project", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let transcript = realDir.appendingPathComponent("sess-2.jsonl")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)

        let resolved = ClaudeHome.transcriptPath(sessionId: "sess-2", cwd: "/totally/different/cwd")
        XCTAssertEqual(resolved, transcript.path)
    }

    func testTranscriptPathReturnsNilForNilOrEmptyCwdWithNoMatch() {
        XCTAssertNil(ClaudeHome.transcriptPath(sessionId: "missing", cwd: nil))
        XCTAssertNil(ClaudeHome.transcriptPath(sessionId: "missing", cwd: ""))
    }

    // MARK: - subagentTranscriptPath / findSubagentTranscriptPath

    func testSubagentTranscriptPathExactMatch() throws {
        let cwd = "/Users/gael/project"
        let encoded = ClaudeHome.encodeCwd(cwd)
        let subagentsDir = tempHome.appendingPathComponent("projects").appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("sess-3", isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let transcript = subagentsDir.appendingPathComponent("agent-ab12.jsonl")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)

        let resolved = ClaudeHome.subagentTranscriptPath(sessionId: "sess-3", cwd: cwd, agentId: "ab12")
        XCTAssertEqual(resolved, transcript.path)
    }

    func testFindSubagentTranscriptPathFuzzyMatchesCompactionPrefix() throws {
        let subagentsDir = tempHome.appendingPathComponent("projects").appendingPathComponent("-proj", isDirectory: true)
            .appendingPathComponent("sess-4", isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let transcript = subagentsDir.appendingPathComponent("agent-acompact-xyz789.jsonl")
        try "{}".write(to: transcript, atomically: true, encoding: .utf8)

        // Requested agentId doesn't match the file's suffix exactly, but the
        // "acompact-" prefix fuzzy match should still find it.
        let resolved = ClaudeHome.findSubagentTranscriptPath(sessionId: "sess-4", agentId: "acompact-different")
        XCTAssertEqual(resolved, transcript.path)
    }

    // MARK: - snapshot paths

    func testSnapshotTranscriptPathUsesDataDirTranscriptsFolder() throws {
        let snapshotDir = tempDataDir.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        let snapshot = snapshotDir.appendingPathComponent("sess-5.jsonl")
        try "{}".write(to: snapshot, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeHome.snapshotTranscriptPath(sessionId: "sess-5"), snapshot.path)
        XCTAssertNil(ClaudeHome.snapshotTranscriptPath(sessionId: "no-such-session"))
    }

    // MARK: - setClaudeHome

    func testSetClaudeHomeValidatesPersistsAndAppliesImmediately() throws {
        let newHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-claude-home-alt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: newHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: newHome) }

        let resolved = try ClaudeHome.setClaudeHome(newHome.path)
        XCTAssertEqual(resolved, newHome.path)
        XCTAssertEqual(ClaudeHome.current(), newHome.path)

        // Persisted: a fresh cache load (simulating a new process) reads it back.
        ClaudeHome.resetOverrideCacheForTesting()
        XCTAssertEqual(ClaudeHome.current(), newHome.path)
    }

    func testSetClaudeHomeRejectsRelativePath() {
        XCTAssertThrowsError(try ClaudeHome.setClaudeHome("relative/path")) { error in
            XCTAssertEqual(error as? ClaudeHomeError, .notAbsolute)
        }
    }

    func testSetClaudeHomeRejectsMissingDirectory() {
        let missing = "/tmp/podium-does-not-exist-\(UUID().uuidString)"
        XCTAssertThrowsError(try ClaudeHome.setClaudeHome(missing)) { error in
            XCTAssertEqual(error as? ClaudeHomeError, .doesNotExist(missing))
        }
    }

    func testSetClaudeHomeRejectsNonDirectory() throws {
        let filePath = tempHome.appendingPathComponent("not-a-dir.txt")
        try "x".write(to: filePath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeHome.setClaudeHome(filePath.path)) { error in
            XCTAssertEqual(error as? ClaudeHomeError, .notADirectory(filePath.path))
        }
    }
}

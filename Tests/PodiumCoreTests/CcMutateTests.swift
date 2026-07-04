import XCTest
@testable import PodiumCore

/// Coverage of `CcMutate` (port of dashboard/server/lib/cc-mutate.js):
/// write/delete on the low-risk text-file surfaces, the mandatory backup
/// mechanism, and the path-traversal guards required by P4.3 item 5.
final class CcMutateTests: XCTestCase {
    private var tempHome: URL!
    private var originalClaudeEnv: [String: String]!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-cc-mutate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        originalClaudeEnv = ClaudeHome.environment
        ClaudeHome.environment = ["CLAUDE_HOME": tempHome.path]
        ClaudeHome.resetOverrideCacheForTesting()
    }

    override func tearDownWithError() throws {
        ClaudeHome.environment = originalClaudeEnv
        ClaudeHome.resetOverrideCacheForTesting()
        try? FileManager.default.removeItem(at: tempHome)
    }

    // MARK: - writeArtifact / deleteArtifact happy path

    func testWriteArtifactCreatesFileWithNoBackupOnFirstWrite() throws {
        let result = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "hello", content: "# hello", cwd: nil)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.created)
        XCTAssertNil(result.backupPath)
        XCTAssertEqual(try String(contentsOfFile: result.file, encoding: .utf8), "# hello")
    }

    func testWriteArtifactOverwriteCreatesBackupOfPreviousContent() throws {
        let first = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "hello", content: "v1", cwd: nil)
        XCTAssertNil(first.backupPath)

        let second = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "hello", content: "v2", cwd: nil)
        XCTAssertFalse(second.created)
        guard let backupPath = second.backupPath else { return XCTFail("expected a backup path on overwrite") }
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "v1")
        XCTAssertEqual(try String(contentsOfFile: second.file, encoding: .utf8), "v2")
    }

    func testWriteArtifactForSkillCreatesDirWithSkillMdFile() throws {
        let result = try CcMutate.writeArtifact(scope: "user", type: "skills", name: "my-skill", content: "# skill body", cwd: nil)
        XCTAssertTrue(result.created)
        XCTAssertTrue(result.file.hasSuffix("SKILL.md"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.target, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testDeleteArtifactBacksUpThenRemoves() throws {
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "gone", content: "bye", cwd: nil)
        let result = try CcMutate.deleteArtifact(scope: "user", type: "commands", name: "gone", cwd: nil)
        XCTAssertTrue(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.target))
        guard let backupPath = result.backupPath else { return XCTFail("delete must always back up first") }
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "bye")
    }

    func testDeleteArtifactMissingTargetThrowsNotFound() {
        XCTAssertThrowsError(try CcMutate.deleteArtifact(scope: "user", type: "commands", name: "nope", cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .notFound)
        }
    }

    // MARK: - Backup rotation (P4.3 item 5)

    func testBackupRotationKeepsEveryPriorVersionListedNewestFirst() throws {
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "rotate", content: "v1", cwd: nil)
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "rotate", content: "v2", cwd: nil)
        // Force a distinct timestamp so the two backup filenames don't collide
        // (the timestamp has second precision).
        Thread.sleep(forTimeInterval: 1.1)
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "rotate", content: "v3", cwd: nil)

        let backups = CcMutate.listBackups(scope: "user", type: "commands", cwd: nil)
        // v1 and v2 both got backed up (the write of v3 backs up v2's content).
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(backups.allSatisfy { $0.name.hasPrefix("rotate.") })
        // Sorted newest-first.
        XCTAssertGreaterThanOrEqual(backups[0].mtime, backups[1].mtime)

        let contents = try backups.map { try String(contentsOfFile: $0.backupPath, encoding: .utf8) }
        XCTAssertTrue(contents.contains("v1"))
        XCTAssertTrue(contents.contains("v2"))
    }

    func testListBackupsFiltersByScopeAndType() throws {
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "a", content: "1", cwd: nil)
        _ = try CcMutate.writeArtifact(scope: "user", type: "commands", name: "a", content: "2", cwd: nil)
        _ = try CcMutate.writeArtifact(scope: "user", type: "agents", name: "b", content: "1", cwd: nil)
        _ = try CcMutate.writeArtifact(scope: "user", type: "agents", name: "b", content: "2", cwd: nil)

        XCTAssertEqual(CcMutate.listBackups(scope: "user", type: "commands", cwd: nil).count, 1)
        XCTAssertEqual(CcMutate.listBackups(scope: "user", type: "agents", cwd: nil).count, 1)
        XCTAssertEqual(CcMutate.listBackups(scope: "user", type: nil, cwd: nil).count, 2)
    }

    // MARK: - Path-traversal guards (P4.3 item 5)

    func testWriteArtifactRejectsNameWithPathTraversal() {
        XCTAssertThrowsError(try CcMutate.writeArtifact(scope: "user", type: "commands", name: "../../etc/passwd", content: "pwned", cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .badName)
        }
    }

    func testWriteArtifactRejectsNameWithEmbeddedSlash() {
        XCTAssertThrowsError(try CcMutate.writeArtifact(scope: "user", type: "skills", name: "sub/dir", content: "x", cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .badName)
        }
    }

    func testWriteArtifactRejectsUnknownType() {
        XCTAssertThrowsError(try CcMutate.writeArtifact(scope: "user", type: "plugins", name: "x", content: "x", cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .badType)
        }
    }

    func testWriteArtifactRejectsUnknownScope() {
        XCTAssertThrowsError(try CcMutate.writeArtifact(scope: "bogus", type: "commands", name: "x", content: "x", cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .badScope)
        }
    }

    func testWriteArtifactRejectsContentOverMaxFileBytes() {
        let tooBig = String(repeating: "a", count: CcConfig.maxFileBytes + 1)
        XCTAssertThrowsError(try CcMutate.writeArtifact(scope: "user", type: "commands", name: "huge", content: tooBig, cwd: nil)) { error in
            XCTAssertEqual((error as? CcMutateError)?.code, .tooLarge)
        }
    }

    func testIsValidNameRejectsTraversalAndEmbeddedSlashesAcceptsNormalNames() {
        XCTAssertTrue(CcMutate.isValidName("my-skill_1.0"))
        XCTAssertFalse(CcMutate.isValidName("../escape"))
        XCTAssertFalse(CcMutate.isValidName("a/b"))
        XCTAssertFalse(CcMutate.isValidName(""))
    }
}

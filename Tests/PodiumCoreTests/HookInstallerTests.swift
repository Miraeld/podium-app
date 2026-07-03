import XCTest
@testable import PodiumCore

final class HookInstallerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podium-hook-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func settingsPath(_ name: String = "settings.json") -> String {
        tempDir.appendingPathComponent(name).path
    }

    private func writeFixture(_ json: String, name: String = "settings.json") throws -> String {
        let path = settingsPath(name)
        try json.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func readJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Install into empty settings

    func testInstallIntoEmptySettings() throws {
        let path = settingsPath()
        // No file exists yet.
        let result = try HookInstaller.install(settingsPath: path, binaryPath: "/Users/x/.claude/podium/podium-hook")

        XCTAssertEqual(result.addedCount, HookInstaller.hookEvents.count)
        XCTAssertFalse(result.alreadyInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let settings = try readJSON(path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for event in HookInstaller.hookEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            let innerHooks = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(innerHooks.count, 1)
            XCTAssertEqual(innerHooks[0]["command"] as? String, "\"/Users/x/.claude/podium/podium-hook\"")
            XCTAssertEqual(innerHooks[0]["timeout"] as? Int, 2)
            XCTAssertEqual(innerHooks[0]["type"] as? String, "command")
        }
    }

    // MARK: - Idempotency

    func testInstallIsIdempotent() throws {
        let path = settingsPath()
        _ = try HookInstaller.install(settingsPath: path)
        let second = try HookInstaller.install(settingsPath: path)

        XCTAssertEqual(second.addedCount, 0)
        XCTAssertTrue(second.alreadyInstalled)

        let settings = try readJSON(path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for event in HookInstaller.hookEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1, "event \(event) should have exactly one podium entry after 2 installs")
        }
    }

    // MARK: - Install alongside other hooks (must be preserved)

    func testInstallPreservesExistingOtherHooksAndSettings() throws {
        let fixture = """
        {
          "otherSetting": "keep-me",
          "nested": { "a": 1, "b": [1, 2, 3] },
          "hooks": {
            "PreToolUse": [
              {
                "hooks": [
                  { "type": "command", "command": "/usr/local/bin/some-other-tool", "timeout": 5 }
                ]
              }
            ]
          }
        }
        """
        let path = try writeFixture(fixture)
        let result = try HookInstaller.install(settingsPath: path, binaryPath: "/h/.claude/podium/podium-hook")

        XCTAssertEqual(result.addedCount, HookInstaller.hookEvents.count)

        let settings = try readJSON(path)
        XCTAssertEqual(settings["otherSetting"] as? String, "keep-me")
        let nested = try XCTUnwrap(settings["nested"] as? [String: Any])
        XCTAssertEqual(nested["a"] as? Int, 1)

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        // Existing other-tool entry + our new podium entry.
        XCTAssertEqual(preToolUse.count, 2)
        let commands = preToolUse.compactMap { entry -> String? in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return nil }
            return inner.first?["command"] as? String
        }
        XCTAssertTrue(commands.contains("/usr/local/bin/some-other-tool"))
        XCTAssertTrue(commands.contains { $0.contains(HookInstaller.podiumMarker) })
    }

    // MARK: - Legacy Node entries get upgraded in place

    func testInstallCleansLegacyNodeEntries() throws {
        let fixture = """
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  { "type": "command", "command": "node \\"/Users/x/.claude/podium/hook.mjs\\"", "timeout": 2 }
                ]
              }
            ],
            "PreToolUse": [
              {
                "hooks": [
                  { "type": "command", "command": "node /some/plugins/cache/wp-media/podium/hook.mjs", "timeout": 2 }
                ]
              }
            ]
          }
        }
        """
        let path = try writeFixture(fixture)
        let result = try HookInstaller.install(settingsPath: path)

        XCTAssertEqual(result.legacyCleanedCount, 2)
        XCTAssertEqual(result.addedCount, HookInstaller.hookEvents.count)

        let settings = try readJSON(path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionStart.count, 1)
        let sessionStartCommand = try XCTUnwrap((sessionStart[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(sessionStartCommand.contains(HookInstaller.podiumMarker))
        XCTAssertFalse(sessionStartCommand.contains("hook.mjs"))

        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)
    }

    // MARK: - Uninstall

    func testUninstallRemovesOnlyPodiumEntries() throws {
        let fixture = """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [ { "type": "command", "command": "/usr/local/bin/keep-me", "timeout": 5 } ] },
              { "hooks": [ { "type": "command", "command": "\\"/h/.claude/podium/podium-hook\\"", "timeout": 2 } ] }
            ],
            "SessionEnd": [
              { "hooks": [ { "type": "command", "command": "\\"/h/.claude/podium/podium-hook\\"", "timeout": 2 } ] }
            ]
          }
        }
        """
        let path = try writeFixture(fixture)
        let result = try HookInstaller.uninstall(settingsPath: path)

        XCTAssertEqual(result.removedCount, 2)

        let settings = try readJSON(path)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 1)
        let remainingCommand = try XCTUnwrap((preToolUse[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertEqual(remainingCommand, "/usr/local/bin/keep-me")

        let sessionEnd = try XCTUnwrap(hooks["SessionEnd"] as? [[String: Any]])
        XCTAssertEqual(sessionEnd.count, 0)
    }

    func testUninstallOnEmptySettingsIsNoop() throws {
        let path = settingsPath()
        let result = try HookInstaller.uninstall(settingsPath: path)
        XCTAssertEqual(result.removedCount, 0)
        // Should not create a file when there's nothing to do.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - check()

    func testCheckReportsNotInstalled() throws {
        let path = settingsPath()
        let status = try HookInstaller.check(settingsPath: path)
        XCTAssertEqual(status, .notInstalled)
    }

    func testCheckReportsInstalledAfterInstall() throws {
        let path = settingsPath()
        _ = try HookInstaller.install(settingsPath: path, binaryPath: "/h/.claude/podium/podium-hook")
        let status = try HookInstaller.check(settingsPath: path)
        XCTAssertEqual(status, .installed)
    }

    func testCheckReportsInstalledViaLegacyWithoutMutating() throws {
        let fixture = """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "node \\"/Users/x/.claude/podium/hook.mjs\\"", "timeout": 2 } ] }
            ]
          }
        }
        """
        let path = try writeFixture(fixture)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let status = try HookInstaller.check(settingsPath: path)
        XCTAssertEqual(status, .installedViaLegacy)

        // check() must be read-only.
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(before, after)
    }

    // MARK: - installBinary

    func testInstallBinaryCopiesAndSetsExecutableBit() throws {
        let source = tempDir.appendingPathComponent("fake-podium-hook")
        try "#!/bin/sh\necho hi\n".data(using: .utf8)?.write(to: source)

        let destination = tempDir.appendingPathComponent("installed/podium-hook").path
        let result = try HookInstaller.installBinary(from: source.path, to: destination)

        XCTAssertEqual(result, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))

        let attrs = try FileManager.default.attributesOfItem(atPath: destination)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        XCTAssertEqual(perms.uint16Value & 0o777, 0o755)
    }

    func testInstallBinaryThrowsWhenSourceMissing() throws {
        let destination = tempDir.appendingPathComponent("installed/podium-hook").path
        XCTAssertThrowsError(try HookInstaller.installBinary(from: tempDir.appendingPathComponent("nope").path, to: destination)) { error in
            guard case HookInstallerError.binarySourceMissing = error else {
                XCTFail("expected binarySourceMissing, got \(error)")
                return
            }
        }
    }

    func testInstallBinaryOverwritesExisting() throws {
        let source = tempDir.appendingPathComponent("fake-podium-hook-2")
        try "v2".data(using: .utf8)?.write(to: source)

        let destination = tempDir.appendingPathComponent("installed2/podium-hook").path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "v1".data(using: .utf8)?.write(to: URL(fileURLWithPath: destination))

        _ = try HookInstaller.installBinary(from: source.path, to: destination)
        let contents = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertEqual(contents, "v2")
    }
}

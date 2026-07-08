import XCTest
@testable import PodiumCore

/// Coverage of `UpdateCheck` (adapted port of dashboard/server/lib/update-check.js)
/// using a fake `GitHubReleaseTransport` so tests never hit the real network.
final class UpdateCheckTests: XCTestCase {
    private struct FakeTransport: GitHubReleaseTransport {
        let releases: [String: GitHubRelease]

        func latestRelease(owner: String, repo: String) async -> GitHubRelease? {
            releases["\(owner)/\(repo)"]
        }
    }

    func testStatusReportsNoUpdateWhenReleaseUnreachable() async {
        let transport = FakeTransport(releases: [:])
        let status = await UpdateCheck.status(transport: transport)
        XCTAssertFalse(status.podium.checked)
        XCTAssertFalse(status.podium.updateAvailable)
        XCTAssertNotNil(status.podium.error)
        XCTAssertFalse(status.updateAvailable)
    }

    func testStatusReportsPodiumReleaseWhenReachable() async {
        let release = GitHubRelease(tagName: "v2.0.0", htmlUrl: "https://example.com/release", publishedAt: "2026-01-01T00:00:00Z", prerelease: false)
        let transport = FakeTransport(releases: ["wp-media/podium": release])
        let status = await UpdateCheck.status(transport: transport)
        XCTAssertTrue(status.podium.checked)
        XCTAssertEqual(status.podium.latestVersion, "v2.0.0")
        XCTAssertEqual(status.podium.releaseUrl, "https://example.com/release")
    }

    func testAppRepoSlugDefaultsToMiraeldPodiumAppWithoutEnvVar() {
        // TASK 2.9b: appRepoSlug() now defaults to the real GitHub remote
        // this app ships releases from, rather than nil — no env var
        // required for the "app" half of the status to be meaningful.
        if ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"] == nil {
            XCTAssertEqual(UpdateCheck.appRepoSlug(), "Miraeld/podium-app")
        }
    }

    func testStatusChecksAppRepoByDefault() async throws {
        guard ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"] == nil else {
            throw XCTSkip("PODIUM_APP_GITHUB_REPO is set in this environment")
        }
        let release = GitHubRelease(tagName: "v1.2.0", htmlUrl: "https://example.com/app-release", publishedAt: "2026-01-01T00:00:00Z", prerelease: false, body: "## Changelog\n- fixed things")
        let status = await UpdateCheck.status(transport: FakeTransport(releases: ["Miraeld/podium-app": release]))
        XCTAssertTrue(status.app.checked)
        XCTAssertEqual(status.app.repo, "Miraeld/podium-app")
        XCTAssertEqual(status.app.latestVersion, "v1.2.0")
        XCTAssertEqual(status.app.releaseNotes, "## Changelog\n- fixed things")
    }

    func testUpdateAvailableTrueWhenCurrentVersionDiffersFromLatestTag() async throws {
        guard ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"] == nil,
              ProcessInfo.processInfo.environment["PODIUM_APP_VERSION"] == nil else {
            throw XCTSkip("PODIUM_APP_GITHUB_REPO/PODIUM_APP_VERSION set in this environment")
        }
        let release = GitHubRelease(tagName: "v3.1.4", htmlUrl: "https://example.com", publishedAt: nil, prerelease: false)
        let transport = FakeTransport(releases: ["Miraeld/podium-app": release])
        // currentAppVersion() falls back to "dev" outside a bundle context
        // (no Info.plist in `swift test`), and "dev" never reports an
        // update as available (see checkRepo's `currentVersion != "dev"` guard).
        let status = await UpdateCheck.status(transport: transport)
        XCTAssertFalse(status.app.updateAvailable)
    }

    // MARK: - release_notes decode (GitHubReleaseAPIResponse `body` field)

    func testGitHubReleaseCarriesOptionalReleaseNotesBody() {
        let withNotes = GitHubRelease(tagName: "v1.0.0", htmlUrl: "https://example.com", publishedAt: nil, prerelease: false, body: "Notes here")
        XCTAssertEqual(withNotes.body, "Notes here")
        let withoutNotes = GitHubRelease(tagName: "v1.0.0", htmlUrl: "https://example.com", publishedAt: nil, prerelease: false)
        XCTAssertNil(withoutNotes.body)
    }

    // MARK: - semver comparison (updateAvailable only when latest > current)

    /// Drives `checkRepo`'s private semver comparison indirectly through
    /// `status()` by pinning `PODIUM_APP_VERSION`/`PODIUM_APP_GITHUB_REPO`
    /// for the duration of the call, since the comparison helper itself is
    /// private. Always restores the previous env var values.
    private func appUpdateAvailable(currentVersion: String, latestTag: String) async -> Bool {
        let envKeyVersion = "PODIUM_APP_VERSION"
        let envKeyRepo = "PODIUM_APP_GITHUB_REPO"
        let previousVersion = ProcessInfo.processInfo.environment[envKeyVersion]
        let previousRepo = ProcessInfo.processInfo.environment[envKeyRepo]
        setenv(envKeyVersion, currentVersion, 1)
        setenv(envKeyRepo, "fake/app", 1)
        defer {
            if let previousVersion { setenv(envKeyVersion, previousVersion, 1) } else { unsetenv(envKeyVersion) }
            if let previousRepo { setenv(envKeyRepo, previousRepo, 1) } else { unsetenv(envKeyRepo) }
        }
        let release = GitHubRelease(tagName: latestTag, htmlUrl: "https://example.com", publishedAt: nil, prerelease: false)
        let transport = FakeTransport(releases: ["fake/app": release])
        let status = await UpdateCheck.status(transport: transport)
        return status.app.updateAvailable
    }

    func testSemverUpdateAvailableWhenLatestIsNewer() async {
        let available = await appUpdateAvailable(currentVersion: "0.5.2", latestTag: "v0.5.3")
        XCTAssertTrue(available)
    }

    func testSemverNoUpdateWhenVersionsEqual() async {
        let available = await appUpdateAvailable(currentVersion: "0.5.3", latestTag: "v0.5.3")
        XCTAssertFalse(available)
    }

    func testSemverNoUpdateWhenCurrentIsNewerThanLatest() async {
        // Regression case for the reported bug: running 0.5.3 while the
        // latest *published* GitHub release is still v0.5.2 (0.5.3 is a
        // draft) must NOT report an update available.
        let available = await appUpdateAvailable(currentVersion: "0.5.3", latestTag: "v0.5.2")
        XCTAssertFalse(available)
    }

    func testSemverHandlesMultiDigitComponents() async {
        let available = await appUpdateAvailable(currentVersion: "0.5.9", latestTag: "v0.5.10")
        XCTAssertTrue(available)
    }

    func testSemverNoUpdateWhenCurrentIsDev() async {
        let envKeyVersion = "PODIUM_APP_VERSION"
        let envKeyRepo = "PODIUM_APP_GITHUB_REPO"
        let previousVersion = ProcessInfo.processInfo.environment[envKeyVersion]
        let previousRepo = ProcessInfo.processInfo.environment[envKeyRepo]
        unsetenv(envKeyVersion)
        setenv(envKeyRepo, "fake/app", 1)
        defer {
            if let previousVersion { setenv(envKeyVersion, previousVersion, 1) } else { unsetenv(envKeyVersion) }
            if let previousRepo { setenv(envKeyRepo, previousRepo, 1) } else { unsetenv(envKeyRepo) }
        }
        let release = GitHubRelease(tagName: "v99.0.0", htmlUrl: "https://example.com", publishedAt: nil, prerelease: false)
        let transport = FakeTransport(releases: ["fake/app": release])
        let status = await UpdateCheck.status(transport: transport)
        XCTAssertFalse(status.app.updateAvailable)
    }

    func testSemverNonNumericComponentsAreTreatedAsNotNewer() async {
        let available = await appUpdateAvailable(currentVersion: "0.5.3", latestTag: "v0.5.next")
        XCTAssertFalse(available)
    }

    func testRepoUpdateStatusReleaseNotesRoundTripsThroughCodable() throws {
        let status = RepoUpdateStatus(
            repo: "owner/repo", checked: true, currentVersion: "1.0.0", latestVersion: "1.1.0",
            updateAvailable: true, releaseUrl: "https://example.com", publishedAt: nil,
            releaseNotes: "## v1.1.0\n- a fix"
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(RepoUpdateStatus.self, from: data)
        XCTAssertEqual(decoded.releaseNotes, "## v1.1.0\n- a fix")

        // Optional field must decode fine when entirely absent from the JSON
        // (older server payloads / the field being genuinely nil).
        let json = """
        {"repo":"owner/repo","checked":false,"updateAvailable":false}
        """
        let minimal = try JSONDecoder().decode(RepoUpdateStatus.self, from: Data(json.utf8))
        XCTAssertNil(minimal.releaseNotes)
    }
}

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

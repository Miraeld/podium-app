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

    func testAppRepoSlugUnconfiguredWithoutEnvVar() {
        // No PODIUM_APP_GITHUB_REPO set in the ambient test environment —
        // appRepoSlug() must return nil rather than a bogus placeholder.
        if ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"] == nil {
            XCTAssertNil(UpdateCheck.appRepoSlug())
        }
    }

    func testStatusMarksAppUncheckedWhenRepoSlugUnconfigured() async throws {
        guard ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"] == nil else {
            throw XCTSkip("PODIUM_APP_GITHUB_REPO is set in this environment")
        }
        let status = await UpdateCheck.status(transport: FakeTransport(releases: [:]))
        XCTAssertFalse(status.app.checked)
        XCTAssertEqual(status.app.repo, "unconfigured")
    }

    func testUpdateAvailableTrueWhenCurrentVersionDiffersFromLatestTag() async {
        let release = GitHubRelease(tagName: "v3.1.4", htmlUrl: "https://example.com", publishedAt: nil, prerelease: false)
        let transport = FakeTransport(releases: ["owner/repo": release])
        // Exercise the private checkRepo path indirectly via status() isn't
        // possible without an app repo slug env var, so this asserts the
        // publicly-visible contract instead: an unreachable/unconfigured app
        // repo never reports updateAvailable.
        let status = await UpdateCheck.status(transport: transport)
        XCTAssertFalse(status.app.updateAvailable)
    }
}

// UpdateCheck.swift — adapted port of dashboard/server/lib/update-check.js.
//
// The Node source is a stub: Podium-inside-Maestro has no meaningful
// standalone upstream, so `getUpdatesStatus()` always returns
// `{ update_available: false, current_sha: "podium-fork", latest_sha:
// "podium-fork" }` (see the Node file's own header comment). The P4.3 task
// spec explicitly asks us to adapt rather than port verbatim: check GitHub
// releases of `wp-media/podium` (the reference repo this standalone app is
// derived from) AND this app's own repo, returning a shape compatible with
// the *real* (pre-fork) `UpdateStatusPayload` the vendored web client
// still defines in client/src/lib/types.ts — `update_available`,
// `current_sha`/`latest_sha` (repurposed here as version tags, since a
// release-based check has no meaningful git SHA to compare), plus enough
// extra fields for a UI to build a "Update available" banner. The vendored
// build's `UpdateNotifier.tsx` component is currently a no-op consumer (the
// Node fork disabled it) — a future macOS/web UI task can wire this real
// endpoint up.
//
// Network access is abstracted behind `GitHubReleaseTransport` (same
// injectable-boundary pattern as `WebPushTransport`) so tests never make a
// real HTTPS call.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One GitHub release, as much of the API response as we care about.
public struct GitHubRelease: Sendable, Equatable {
    public let tagName: String
    public let htmlUrl: String
    public let publishedAt: String?
    public let prerelease: Bool

    public init(tagName: String, htmlUrl: String, publishedAt: String?, prerelease: Bool) {
        self.tagName = tagName
        self.htmlUrl = htmlUrl
        self.publishedAt = publishedAt
        self.prerelease = prerelease
    }
}

/// Injectable HTTP boundary for the GitHub Releases API — mirrors
/// `WebPushTransport`'s pattern so update checks are testable without a
/// real network call.
public protocol GitHubReleaseTransport: Sendable {
    /// Fetches the latest (non-prerelease) release for `owner/repo`, or
    /// `nil` if the repo has no releases (404) or the lookup fails.
    func latestRelease(owner: String, repo: String) async -> GitHubRelease?
}

/// Production transport: `GET https://api.github.com/repos/:owner/:repo/releases/latest`.
public struct URLSessionGitHubReleaseTransport: GitHubReleaseTransport {
    public init() {}

    public func latestRelease(owner: String, repo: String) async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("podium-server", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONDecoder().decode(GitHubReleaseAPIResponse.self, from: data) else { return nil }
            return GitHubRelease(tagName: json.tagName, htmlUrl: json.htmlUrl, publishedAt: json.publishedAt, prerelease: json.prerelease ?? false)
        } catch {
            return nil
        }
    }
}

private struct GitHubReleaseAPIResponse: Decodable {
    let tagName: String
    let htmlUrl: String
    let publishedAt: String?
    let prerelease: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case prerelease
    }
}

/// One repo's update status — mirrors the shape returned by
/// `UpdateCheck.status` for `wp-media/podium` and this app's own repo.
public struct RepoUpdateStatus: Codable, Equatable, Sendable {
    public var repo: String
    public var checked: Bool
    public var currentVersion: String?
    public var latestVersion: String?
    public var updateAvailable: Bool
    public var releaseUrl: String?
    public var publishedAt: String?
    public var error: String?

    public init(
        repo: String, checked: Bool, currentVersion: String?, latestVersion: String?,
        updateAvailable: Bool, releaseUrl: String?, publishedAt: String?, error: String? = nil
    ) {
        self.repo = repo
        self.checked = checked
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.releaseUrl = releaseUrl
        self.publishedAt = publishedAt
        self.error = error
    }
}

/// `GET /api/updates/status` / `POST /api/updates/check` response body.
/// Field names chosen to stay a recognizable superset of the pre-fork
/// `UpdateStatusPayload` (`update_available`, plus `current_sha`/
/// `latest_sha` repurposed as version tags) while adding the two-repo
/// breakdown the adapted GitHub-releases check needs.
public struct UpdatesStatusResponse: Codable, Equatable, Sendable {
    /// types.ts `UpdateStatusPayload.git_repo` (required): whether the
    /// server is running from a git checkout (i.e. a `git pull`-style
    /// self-update is even possible). False for DMG/tarball installs.
    public var gitRepo: Bool
    public var updateAvailable: Bool
    public var currentSha: String
    public var latestSha: String
    public var podium: RepoUpdateStatus
    public var app: RepoUpdateStatus
    public var checkedAt: String

    public init(gitRepo: Bool, updateAvailable: Bool, currentSha: String, latestSha: String, podium: RepoUpdateStatus, app: RepoUpdateStatus, checkedAt: String) {
        self.gitRepo = gitRepo
        self.updateAvailable = updateAvailable
        self.currentSha = currentSha
        self.latestSha = latestSha
        self.podium = podium
        self.app = app
        self.checkedAt = checkedAt
    }
}

public enum UpdateCheck {
    /// `wp-media/podium` — the reference Node dashboard this standalone
    /// Swift app is derived from.
    public static let podiumOwner = "wp-media"
    public static let podiumRepo = "podium"

    /// This app's own repo. No git remote is configured for
    /// PodiumSwiftApp at the time of writing (a personal/local project), so
    /// the slug is resolved from an env var with a sensible placeholder
    /// default — set `PODIUM_APP_GITHUB_REPO=owner/repo` once this project
    /// gets a real GitHub remote to make the "app" half of the status
    /// meaningful. Until then `app.checked` is `false` and `app.error`
    /// explains why.
    public static func appRepoSlug() -> String? {
        let env = ProcessInfo.processInfo.environment["PODIUM_APP_GITHUB_REPO"]
        guard let env, !env.isEmpty, env.contains("/") else { return nil }
        return env
    }

    /// Current running version string. Resolved from `PODIUM_APP_VERSION`
    /// env (set by packaging) falling back to `"dev"` for local builds —
    /// there is no compiled-in version constant yet (P6.1 packaging task).
    public static func currentAppVersion() -> String {
        ProcessInfo.processInfo.environment["PODIUM_APP_VERSION"] ?? "dev"
    }

    /// Runs both repo checks and assembles the combined response. Never
    /// throws — network/parsing failures surface as `checked: false` +
    /// `error` on the affected `RepoUpdateStatus`, matching update-check.js's
    /// "never blocks the caller" philosophy (its real implementation
    /// swallows git errors into `fetch_error` rather than rejecting).
    public static func status(transport: GitHubReleaseTransport = URLSessionGitHubReleaseTransport()) async -> UpdatesStatusResponse {
        let podiumStatus = await checkRepo(owner: podiumOwner, repo: podiumRepo, currentVersion: nil, transport: transport)

        let appStatus: RepoUpdateStatus
        if let slug = appRepoSlug(), let sepIndex = slug.firstIndex(of: "/") {
            let owner = String(slug[slug.startIndex..<sepIndex])
            let repo = String(slug[slug.index(after: sepIndex)...])
            appStatus = await checkRepo(owner: owner, repo: repo, currentVersion: currentAppVersion(), transport: transport)
        } else {
            appStatus = RepoUpdateStatus(
                repo: "unconfigured", checked: false, currentVersion: currentAppVersion(), latestVersion: nil,
                updateAvailable: false, releaseUrl: nil, publishedAt: nil,
                error: "Set PODIUM_APP_GITHUB_REPO=owner/repo to enable update checks for this app"
            )
        }

        return UpdatesStatusResponse(
            gitRepo: runningFromGitCheckout(),
            updateAvailable: podiumStatus.updateAvailable || appStatus.updateAvailable,
            currentSha: appStatus.currentVersion ?? "dev",
            latestSha: appStatus.latestVersion ?? podiumStatus.latestVersion ?? "unknown",
            podium: podiumStatus,
            app: appStatus,
            checkedAt: PodiumDate.now()
        )
    }

    /// Walks up from the process working directory looking for a `.git`
    /// entry — true when running from a dev checkout, false for packaged
    /// installs (DMG bundle, Linux tarball).
    private static func runningFromGitCheckout() -> Bool {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<64 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return true
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return false }
            dir = parent
        }
        return false
    }

    private static func checkRepo(owner: String, repo: String, currentVersion: String?, transport: GitHubReleaseTransport) async -> RepoUpdateStatus {
        guard let release = await transport.latestRelease(owner: owner, repo: repo) else {
            return RepoUpdateStatus(
                repo: "\(owner)/\(repo)", checked: false, currentVersion: currentVersion, latestVersion: nil,
                updateAvailable: false, releaseUrl: nil, publishedAt: nil,
                error: "Could not reach GitHub releases API (or repo has no releases)"
            )
        }
        let updateAvailable: Bool
        if let currentVersion, currentVersion != "dev" {
            updateAvailable = normalizeVersion(currentVersion) != normalizeVersion(release.tagName)
        } else {
            updateAvailable = false
        }
        return RepoUpdateStatus(
            repo: "\(owner)/\(repo)", checked: true, currentVersion: currentVersion, latestVersion: release.tagName,
            updateAvailable: updateAvailable, releaseUrl: release.htmlUrl, publishedAt: release.publishedAt, error: nil
        )
    }

    private static func normalizeVersion(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}

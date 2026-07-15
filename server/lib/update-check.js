/**
 * @file Detects whether a newer release of THIS app (Podium) is available on
 * GitHub. ROADMAP N3 — ADAPT per docs/N2-GAP.md: the upstream Node original
 * this file replaces (`hoangsonww/Claude-Code-Agent-Monitor`) implemented an
 * entirely different git-remote-diff mechanism (comparing the local checkout
 * against `upstream/master`) that has no meaning for a Tauri-packaged
 * standalone desktop app with no "canonical git remote" to diff against, and
 * whose response shape doesn't match what the client actually reads
 * (`client/src/lib/types.ts`'s `RepoUpdatesStatusResponse`).
 *
 * Ported from `Sources/PodiumCore/Discovery/UpdateCheck.swift` +
 * `Sources/PodiumServer/Routes/UpdatesRouter.swift`: check the latest GitHub
 * release of this app's own repo, and prompt only when it is strictly newer
 * (numeric semver compare) than the running version.
 *
 *   P2 (ROADMAP §2): `update_available` is only ever true when the latest
 *   release is STRICTLY newer than the current version by numeric semver
 *   comparison. A `current` of `"dev"`/unset, or a version string that can't
 *   be parsed as dot-separated integers, always yields `false` — never a
 *   false-positive prompt from string inequality.
 *   P7 (ROADMAP §2): checks ONLY this app's own repo — default
 *   `Miraeld/podium-app` — override via `PODIUM_APP_GITHUB_REPO=owner/repo`
 *   (e.g. pointing a dev build at a fork). Never the frozen plugin-era
 *   `wp-media/podium` reference repo.
 *
 * @author Gael Robin <robin.gael@gmail.com>
 */

const fs = require("fs");
const path = require("path");

const DEFAULT_APP_REPO = "Miraeld/podium-app";
const GITHUB_API_TIMEOUT_MS = 5_000;

/** P7: this app's own repo slug — env override, else the hardcoded default. */
function appRepoSlug() {
  const env = (process.env.PODIUM_APP_GITHUB_REPO || "").trim();
  if (env && env.includes("/")) return env;
  return DEFAULT_APP_REPO;
}

/**
 * Current running version string. `PODIUM_APP_VERSION` is stamped in at
 * build/release time (P8); falls back to `"dev"` for local/dev runs — which
 * `isNewer` always treats as "never prompt" (P2).
 */
function currentAppVersion() {
  const env = (process.env.PODIUM_APP_VERSION || "").trim();
  return env || "dev";
}

/**
 * Walks up from `startDir` looking for a `.git` entry — true when running
 * from a dev checkout, false for packaged installs (DMG bundle, Linux
 * tarball, bun-compiled sidecar).
 */
function runningFromGitCheckout(startDir = path.join(__dirname, "..", "..")) {
  let dir = path.resolve(startDir);
  for (let i = 0; i < 64; i++) {
    if (fs.existsSync(path.join(dir, ".git"))) return true;
    const parent = path.dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
  return false;
}

function normalizeVersion(version) {
  return version.startsWith("v") ? version.slice(1) : version;
}

/**
 * Semantic-version comparison: `true` only when `lhs` (latest) is strictly
 * newer than `rhs` (current). Splits each on ".", compares numeric
 * components left-to-right (missing trailing components treated as `0`). If
 * either version contains a non-numeric component, the versions can't be
 * reliably compared — return `false` (no update prompt) rather than guessing
 * from string inequality (P2's exact false-positive class this fixes: a
 * running dev build "0.5.3" vs. a still-draft "0.5.2" release must never
 * look "newer" from naive string comparison).
 */
function isNewer(lhs, rhs) {
  const lhsParts = lhs.split(".");
  const rhsParts = rhs.split(".");
  const count = Math.max(lhsParts.length, rhsParts.length);
  for (let i = 0; i < count; i++) {
    const lhsComponent = i < lhsParts.length ? lhsParts[i] : "0";
    const rhsComponent = i < rhsParts.length ? rhsParts[i] : "0";
    if (!/^\d+$/.test(lhsComponent) || !/^\d+$/.test(rhsComponent)) return false;
    const lhsNumber = parseInt(lhsComponent, 10);
    const rhsNumber = parseInt(rhsComponent, 10);
    if (lhsNumber !== rhsNumber) return lhsNumber > rhsNumber;
  }
  return false;
}

/**
 * Fetch the latest (non-prerelease, non-draft — GitHub's `/releases/latest`
 * already excludes both) release for `owner/repo`. Returns `null` on any
 * failure (network error, 404/no releases, timeout, malformed body) — update
 * checks never throw, matching the "never blocks the caller" philosophy of
 * the upstream file this replaces.
 */
async function fetchLatestRelease(owner, repo) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), GITHUB_API_TIMEOUT_MS);
  try {
    const res = await fetch(`https://api.github.com/repos/${owner}/${repo}/releases/latest`, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "podium-server",
      },
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const json = await res.json();
    if (!json || typeof json.tag_name !== "string") return null;
    return {
      tagName: json.tag_name,
      htmlUrl: typeof json.html_url === "string" ? json.html_url : null,
      publishedAt: typeof json.published_at === "string" ? json.published_at : null,
      body: typeof json.body === "string" ? json.body : null,
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Checks one repo and builds its `RepoUpdateStatus` (client/src/lib/types.ts).
 */
async function checkRepo(owner, repo, currentVersion) {
  const release = await fetchLatestRelease(owner, repo);
  if (!release) {
    return {
      repo: `${owner}/${repo}`,
      checked: false,
      current_version: currentVersion,
      latest_version: null,
      update_available: false,
      release_url: null,
      published_at: null,
      error: "Could not reach GitHub releases API (or repo has no releases)",
    };
  }
  const updateAvailable =
    currentVersion && currentVersion !== "dev"
      ? isNewer(normalizeVersion(release.tagName), normalizeVersion(currentVersion))
      : false;
  return {
    repo: `${owner}/${repo}`,
    checked: true,
    current_version: currentVersion,
    latest_version: release.tagName,
    update_available: updateAvailable,
    release_url: release.htmlUrl,
    published_at: release.publishedAt,
    error: null,
    release_notes: release.body,
  };
}

/**
 * Runs the GitHub-release check and assembles the `RepoUpdatesStatusResponse`
 * (client/src/lib/types.ts) — the shape `GET /api/updates/status` and
 * `POST /api/updates/check` both return. Never throws.
 */
async function getUpdatesStatus() {
  const currentVersion = currentAppVersion();
  const slug = appRepoSlug();
  const sepIdx = slug.indexOf("/");
  let appStatus;
  if (sepIdx === -1) {
    appStatus = {
      repo: "unconfigured",
      checked: false,
      current_version: currentVersion,
      latest_version: null,
      update_available: false,
      release_url: null,
      published_at: null,
      error: "Set PODIUM_APP_GITHUB_REPO=owner/repo to enable update checks for this app",
    };
  } else {
    const owner = slug.slice(0, sepIdx);
    const repo = slug.slice(sepIdx + 1);
    appStatus = await checkRepo(owner, repo, currentVersion);
  }

  return {
    git_repo: runningFromGitCheckout(),
    update_available: appStatus.update_available,
    current_sha: appStatus.current_version || "dev",
    latest_sha: appStatus.latest_version || "unknown",
    app: appStatus,
    checked_at: new Date().toISOString(),
  };
}

module.exports = {
  getUpdatesStatus,
  appRepoSlug,
  currentAppVersion,
  isNewer,
  normalizeVersion,
  DEFAULT_APP_REPO,
};

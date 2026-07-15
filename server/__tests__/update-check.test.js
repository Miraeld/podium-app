/**
 * @file Tests for the GitHub-releases-based update check (ROADMAP §2 P2/P7),
 * which replaced the git-remote-diff mechanism this file used to test (that
 * mechanism has no meaning for a Tauri-packaged standalone desktop app with
 * no "canonical git remote" — see lib/update-check.js's header). Network
 * access is stubbed via a fake `global.fetch` so these run fully offline and
 * deterministically — no real GitHub calls, no flakiness.
 * @author Gael Robin <robin.gael@gmail.com>
 */

const { describe, it, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const {
  getUpdatesStatus,
  appRepoSlug,
  currentAppVersion,
  isNewer,
  normalizeVersion,
  DEFAULT_APP_REPO,
} = require("../lib/update-check");

const ENV_KEYS = ["PODIUM_APP_GITHUB_REPO", "PODIUM_APP_VERSION"];
const realFetch = global.fetch;

afterEach(() => {
  for (const k of ENV_KEYS) delete process.env[k];
  global.fetch = realFetch;
});

/** Install a fake `global.fetch` returning a canned GitHub release response. */
function stubRelease(release) {
  global.fetch = async () => ({
    ok: true,
    json: async () => release,
  });
}

function stubUnreachable() {
  global.fetch = async () => ({ ok: false, status: 404 });
}

describe("appRepoSlug (P7 — Miraeld/podium-app only)", () => {
  it("defaults to Miraeld/podium-app", () => {
    assert.equal(appRepoSlug(), "Miraeld/podium-app");
    assert.equal(DEFAULT_APP_REPO, "Miraeld/podium-app");
  });
  it("never falls back to the frozen plugin-era wp-media/podium repo", () => {
    assert.notEqual(appRepoSlug(), "wp-media/podium");
  });
  it("honors PODIUM_APP_GITHUB_REPO override", () => {
    process.env.PODIUM_APP_GITHUB_REPO = "someone/fork";
    assert.equal(appRepoSlug(), "someone/fork");
  });
  it("ignores a malformed override with no slash", () => {
    process.env.PODIUM_APP_GITHUB_REPO = "not-a-valid-slug";
    assert.equal(appRepoSlug(), "Miraeld/podium-app");
  });
});

describe("currentAppVersion", () => {
  it("defaults to 'dev'", () => {
    assert.equal(currentAppVersion(), "dev");
  });
  it("honors PODIUM_APP_VERSION", () => {
    process.env.PODIUM_APP_VERSION = "1.2.3";
    assert.equal(currentAppVersion(), "1.2.3");
  });
});

describe("normalizeVersion", () => {
  it("strips a leading v", () => {
    assert.equal(normalizeVersion("v1.2.3"), "1.2.3");
    assert.equal(normalizeVersion("1.2.3"), "1.2.3");
  });
});

describe("isNewer (P2 — strictly-newer numeric semver only)", () => {
  it("true when lhs is strictly greater", () => {
    assert.equal(isNewer("1.2.3", "1.2.2"), true);
    assert.equal(isNewer("2.0.0", "1.9.9"), true);
    assert.equal(isNewer("1.10.0", "1.9.0"), true); // numeric, not lexicographic
  });
  it("false when equal", () => {
    assert.equal(isNewer("1.2.3", "1.2.3"), false);
  });
  it("false when lhs is older", () => {
    assert.equal(isNewer("1.2.2", "1.2.3"), false);
  });
  it("treats missing trailing components as 0", () => {
    assert.equal(isNewer("1.3", "1.2.9"), true);
    assert.equal(isNewer("1.2", "1.2.0"), false);
  });
  it("never guesses from string inequality — unparseable component means false", () => {
    assert.equal(isNewer("1.2.3-beta", "1.2.2"), false);
    assert.equal(isNewer("abc", "1.2.2"), false);
  });
});

describe("getUpdatesStatus (P2/P7 end-to-end, network stubbed)", () => {
  it("dev current version never reports an update, even against a newer release", async () => {
    stubRelease({
      tag_name: "v99.0.0",
      html_url: "https://github.com/Miraeld/podium-app/releases/tag/v99.0.0",
      published_at: "2026-01-01T00:00:00Z",
      body: "notes",
    });
    const result = await getUpdatesStatus();
    assert.equal(result.update_available, false);
    assert.equal(result.current_sha, "dev");
    assert.equal(result.app.checked, true);
    assert.equal(result.app.repo, "Miraeld/podium-app");
  });

  it("strictly-newer release with a real current version reports update_available", async () => {
    process.env.PODIUM_APP_VERSION = "1.0.0";
    stubRelease({
      tag_name: "v1.1.0",
      html_url: "https://github.com/Miraeld/podium-app/releases/tag/v1.1.0",
      published_at: "2026-01-01T00:00:00Z",
      body: null,
    });
    const result = await getUpdatesStatus();
    assert.equal(result.update_available, true);
    assert.equal(result.current_sha, "1.0.0");
    assert.equal(result.latest_sha, "v1.1.0");
    assert.equal(result.app.update_available, true);
  });

  it("current version equal to or newer than latest never reports an update", async () => {
    process.env.PODIUM_APP_VERSION = "2.0.0";
    stubRelease({ tag_name: "v1.9.0", html_url: null, published_at: null, body: null });
    const result = await getUpdatesStatus();
    assert.equal(result.update_available, false);
  });

  it("an unreachable GitHub API never throws — checked:false with an error", async () => {
    stubUnreachable();
    const result = await getUpdatesStatus();
    assert.equal(result.update_available, false);
    assert.equal(result.app.checked, false);
    assert.ok(result.app.error);
  });

  it("PODIUM_APP_GITHUB_REPO override is honored end-to-end", async () => {
    process.env.PODIUM_APP_GITHUB_REPO = "someone/fork";
    stubRelease({ tag_name: "v1.0.0", html_url: null, published_at: null, body: null });
    const result = await getUpdatesStatus();
    assert.equal(result.app.repo, "someone/fork");
  });

  it("always returns the RepoUpdatesStatusResponse shape (client/src/lib/types.ts)", async () => {
    stubRelease({ tag_name: "v1.0.0", html_url: null, published_at: null, body: null });
    const result = await getUpdatesStatus();
    assert.equal(typeof result.git_repo, "boolean");
    assert.equal(typeof result.update_available, "boolean");
    assert.equal(typeof result.current_sha, "string");
    assert.equal(typeof result.latest_sha, "string");
    assert.equal(typeof result.checked_at, "string");
    assert.equal(typeof result.app, "object");
  });
});

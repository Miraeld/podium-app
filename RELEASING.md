# Releasing

Cut a release: `git tag vX.Y.Z && git push --tags`.

`.github/workflows/release.yml` then builds and publishes a GitHub release
for that tag: a signed-ad-hoc `Podium_X.Y.Z_<arch>.dmg` (macOS, Tauri) and
`Podium_X.Y.Z_<arch>.AppImage` + `Podium_X.Y.Z_<arch>.deb` (Linux, also
Tauri), plus auto-generated release notes.

## What the release workflow does (Node era, N6)

Both the `macos` and `linux` jobs:

1. Stamp `tauri/src-tauri/tauri.conf.json`'s `"version"` from the tag (so the
   `.dmg`/`.app` Info.plist and the future updater manifest agree with the
   GitHub release).
2. Build the React client with `PODIUM_APP_VERSION=<version>` set — **P8: the
   client's build guard makes a version-less build fail on purpose; this is
   never weakened, and the release job always sets the real tag version, not
   `ci`/`dev`.**
3. Run `tauri/prepare-sidecar.sh`, which:
   - `bun install --production` + `bun build --compile --external
     better-sqlite3` in `server/` (with `NODE_ENV=production` — this must be
     set at *build* time, not just runtime, because bun's bundler statically
     inlines `process.env.NODE_ENV` reads; see the script's own header
     comment for the full rationale and the native-module footgun it avoids),
     staging the result as `tauri/src-tauri/bin/podium-server-<rust-triple>`.
   - Copies `client/dist` into `tauri/src-tauri/web-dist/` (a Tauri bundle
     resource — the packaged app has no other way to find the dashboard
     assets relative to the sidecar binary).
4. `cargo tauri build` produces the installers.

CI installs `bun` via `oven-sh/setup-bun` before this runs (both jobs) — the
sidecar is a bun-compiled binary now, not a Swift build product.

**Linux runner architecture:** GitHub's `ubuntu-latest` runners are x86_64,
and `bun build --compile` defaults to the host's own architecture, so the
plain (non-cross) compile in the `linux` job already produces an x86_64
Linux binary without any extra flag — which is what most Linux desktop users
want. If this job is ever moved to a different-arch runner (e.g. aarch64),
pass an explicit `--target=bun-linux-x64` (or the matching target string) to
the `bun build --compile` invocation inside `tauri/prepare-sidecar.sh` rather
than relying on the host default.

## macOS: ad-hoc signing, no notarization

`tauri.conf.json`'s `bundle.macOS.signingIdentity` is `"-"` (ad-hoc) — there
is no Apple Developer ID on this project (owner declined notarization), so
the `.dmg`/`.app` is **not notarized**. A downloaded/copied ad-hoc `.app`
hits Gatekeeper's "unidentified developer" warning on first launch. One-time
fix per machine, after installing to `/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/Podium.app
```

(or right-click the app → **Open** → confirm in the dialog, instead of
double-clicking). This is already documented in `README.md`'s install
instructions — keep both in sync if this dance ever changes (e.g. if a
Developer ID is added later and notarization replaces it).

In-app updates are check-only: the popup links out to the GitHub release
page for the user to download and replace manually (no self-updater yet —
see the `TODO(T2.3)` comments in `release.yml`).

## Headless Linux (separate from the Tauri release artifacts)

`scripts/build-linux.sh` produces a `podium-linux-<version>-<arch>.tar.gz` —
a separate, manual headless-server-only path (bun-compiled `podium-server` +
`podium-hook` binaries, the vendored web client, and `install-linux.sh`, no
GUI shell), **not** something CI builds or `release.yml` uploads. Don't
confuse it with the Linux release artifacts above.

This path deploys the Node server as a **bun-compiled single-file binary**
(same build recipe as the Tauri sidecar), not `node` + `npm ci` on the
target host — chosen because it needs no Node/npm/`node_modules` on the
machine at all (just glibc), and keeps exactly one build recipe for "Node
server as a native-feeling binary" instead of two. See
`scripts/build-linux.sh`'s header comment for the full rationale.

```bash
scripts/build-linux.sh              # builds inside docker (oven/bun:1) if
                                     # docker is available, else the host's
                                     # own bun (must be running on Linux)
# on the target machine:
tar xzf podium-linux-<version>-<arch>.tar.gz
cd podium-linux-<version>-<arch>
./install-linux.sh
```

`install-linux.sh` installs both binaries to `/usr/local/bin/`, the web
dashboard to `/usr/local/share/podium/web/`, and a systemd **user** unit
(`scripts/podium-server.service`) that starts the server automatically.
Note the unit sets `Environment=DASHBOARD_WEB_DIST=/usr/local/share/podium/web`
— without it the compiled binary can't find the dashboard assets on this
install layout (its built-in fallback path only resolves inside the source
tree it was compiled from) and `/` 404s while the API still works.

`Environment=PODIUM_HOST=0.0.0.0` in that unit is an explicit, documented
opt-in to LAN exposure (P1: the server defaults to loopback-only, and that
default is a security fix — never regress it for convenience). The
run-spawning endpoints (`POST /api/run`) have no authentication, so only run
this unit on a trusted network, behind a reverse proxy / VPN if it needs to
be reachable from anywhere less trusted.

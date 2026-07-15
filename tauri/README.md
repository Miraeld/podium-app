# Podium — Tauri desktop shell

A minimal [Tauri v2](https://v2.tauri.app) native app that bundles the
bun-compiled `podium-server` binary as a **sidecar** and shows the live web
dashboard in a native window. One native app on macOS + Linux, a Node server
(compiled to a single-file binary) as the bundled backend, the React
dashboard (built from `client/`, served *by* `podium-server`) as the UI.

The window doesn't ship any web assets of its own — `podium-server` already
serves `client/dist` (staged into the bundle as `web-dist/`) over HTTP, so the
shell just spawns the server, waits for `GET /api/health` to return 200, then
navigates the window to `http://127.0.0.1:<port>`.

## How it works (lifecycle)

On launch (`src-tauri/src/main.rs`, the Tauri `setup` hook):

1. If a server already answers `GET /api/health` on the target port (default
   **4820**), **reuse it** — don't spawn a second one.
2. Otherwise spawn the `podium-server` sidecar with
   `--port <port> --data-dir <platform data dir>`, matching the server's own
   platform-default data dir exactly, so the app reads the user's **existing
   DB**:
   - macOS: `~/Library/Application Support/Podium`
   - Linux: `$XDG_DATA_HOME/podium`, else `~/.local/share/podium`
3. Poll `/api/health` until 200 (timeout ~15s), then navigate the window to
   `http://127.0.0.1:<port>`.

On window-close / app-quit: the sidecar is terminated **only if this app
spawned it** (a reused pre-existing server is left alone). Both the
`CloseRequested` window event and the `RunEvent::Exit` app event trigger the
kill, so no orphaned `podium-server` survives.

Override the port with the `PODIUM_PORT` env var.

## Prerequisites

- **Rust toolchain** (rustc/cargo) — install via [rustup](https://rustup.rs):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"
  ```
- **Tauri CLI v2**:
  ```bash
  cargo install tauri-cli --version "^2.0.0" --locked
  ```
- **Xcode Command Line Tools** (macOS) — already present on the dev box.
- **[bun](https://bun.sh)** — to bun-compile the `podium-server` and
  `podium-hook` sidecars.
- On **Linux**, Tauri needs WebKitGTK + build deps (see the Tauri Linux
  prerequisites docs) — CI installs these directly on `ubuntu-latest`, no
  container required (see `.github/workflows/release.yml`).

## Build the sidecar (required before dev/build)

The sidecar binaries must be staged under `src-tauri/bin/` with the Rust
target triple suffix Tauri expects (e.g.
`podium-server-aarch64-apple-darwin`). Use the helper script:

```bash
tauri/prepare-sidecar.sh
```

It runs `bun install --production` + `NODE_ENV=production bun build
--compile --external better-sqlite3` against `server/` and `hook/`, copies
the resulting single-file binaries to `src-tauri/bin/podium-server-<triple>`
and `src-tauri/bin/podium-hook-<triple>`, and stages `client/dist` →
`src-tauri/web-dist/`. Re-run it whenever the server, hook, or client
changes. `BUN_NO_CODESIGN_MACHO_BINARY=1` is set on both compiles — bun
1.3.14's own Mach-O self-signing is broken and corrupts the binary before
Tauri's codesign pass runs.

> The staged binary and generated icons are **git-ignored** (they're build
> artifacts). Regenerate the icon set from the source PNG with
> `cargo tauri icon src-tauri/icon-source.png` if `src-tauri/icons/` is empty.

## Run (development)

From the `tauri/` directory:

```bash
cargo tauri dev
```

This compiles the Rust shell, stages nothing extra (the sidecar is already in
`src-tauri/bin/`), opens the "Podium" window, spawns `podium-server`, waits
for health, and loads the live dashboard against your real DB.

## Build (release installers)

```bash
tauri/prepare-sidecar.sh   # rebuild + restage the sidecars AND client/dist
cd tauri
cargo tauri build
```

Produces (per `tauri.conf.json` `bundle.targets`):

- macOS: `Podium.app` + `Podium_<version>_aarch64.dmg` under
  `src-tauri/target/release/bundle/{macos,dmg}/`
- Linux: `.AppImage` + `.deb` under
  `src-tauri/target/release/bundle/{appimage,deb}/` — built directly on an
  `ubuntu-latest` runner in CI (`.github/workflows/release.yml`), no
  container needed since the sidecar is a bun-compiled binary, not a Swift
  build product requiring a matched toolchain image.

### macOS signing (T1.2 — ad-hoc only, no paid Developer ID)

`tauri.conf.json`'s `bundle.macOS.signingIdentity` is `"-"` (ad-hoc). There
is no Apple Developer ID on this project, so the app is **not notarized**.
A downloaded/copied ad-hoc `.app` hits Gatekeeper on first launch. One-time
fix after installing to `/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/Podium.app
```

(or right-click the app → Open → confirm in the dialog, instead of
double-clicking). This is a permanent, one-time step per machine — once the
quarantine flag is cleared, subsequent launches work normally.

### Native glass (vibrancy)

The window uses the `window-vibrancy` crate (pinned to `0.6`, matching the
version `tauri` itself vendors internally under `macos-private-api` — a
mismatched semver pulls a second copy of the same Cocoa shims and the
linker fails with "symbol multiply defined") to apply an `NSVisualEffectView`
with the `HudWindow` material behind the window. The window is
also `transparent: true` (requires `app.macOSPrivateApi: true` in
`tauri.conf.json`) so the webview doesn't paint an opaque backing over the
vibrancy — the web dashboard's own CSS glass (`backdrop-filter`) then
composites on top of the native wallpaper blur.

**Manual verification** (structural checks don't prove the visual look):
launch `/Applications/Podium.app`, and confirm the window shows the blurred
desktop wallpaper behind translucent regions of the dashboard, not a flat
opaque background. `defaults write com.apple.universalaccess
reduceTransparency -bool true` (System Settings → Accessibility →
Display → Reduce Transparency) should make it fall back to a flat color
gracefully, matching the web CSS's own reduced-motion/transparency handling.

### The `--web-dist` wire-up

`podium-server`'s static file resolver only knows two places to find the web
client: the `DASHBOARD_WEB_DIST`/`--web-dist` override, or the repo-relative
default `client/dist`. A Tauri `.app` bundle has neither by default — the
sidecar binary lives at `Contents/MacOS/podium-server` with no `client/dist`
alongside it — so without this wiring `/` 404s and the window shows nothing
but the vibrancy blur.

1. `prepare-sidecar.sh` copies `client/dist` → `src-tauri/web-dist/`
   (gitignored build artifact, same treatment as the staged sidecar binary).
2. `tauri.conf.json`'s `bundle.resources` includes `"web-dist/"`, so Tauri
   copies it into `Contents/Resources/web-dist/` in the final bundle,
   preserving the `assets/` subdirectory (a `"web-dist/*"` or
   `"web-dist/**/*"` glob mapped to a single flat destination silently
   flattens subdirectories — use the plain directory-path array form
   instead: `"resources": ["web-dist/"]`).
3. `main.rs` resolves `app.path().resource_dir()` and, if
   `<resource_dir>/web-dist` exists, passes
   `--web-dist <resource_dir>/web-dist` when spawning the sidecar. If the
   resource is missing (e.g. `prepare-sidecar.sh` wasn't re-run before a
   build), it logs a warning and continues — the API still works, only the
   web UI 404s, rather than panicking.

**Always re-run `tauri/prepare-sidecar.sh` before `cargo tauri build`** if
`server/`, `hook/`, or `client/` changed.

### Linux: `.AppImage` + `.deb`

Built directly on an `ubuntu-latest` GitHub Actions runner
(`.github/workflows/release.yml`'s `linux` job) — no container or
cross-compile toolchain needed, since the sidecar is a bun-compiled
single-file binary (glibc, not a Swift build product requiring a matched
toolchain image). The job installs the Tauri Linux build deps (WebKitGTK
etc.), runs `tauri/prepare-sidecar.sh`, then `cargo tauri build --bundles
appimage,deb`. You cannot build (or run) the Linux GUI app directly on macOS
— Tauri Linux needs WebKitGTK + a Linux userland; use CI or a Linux VM.
`scripts/build-linux.sh` covers the separate headless-server (no GUI) path.

## Verify no orphaned server

After closing the window:

```bash
lsof -iTCP:4820 -sTCP:LISTEN   # should print nothing
pgrep -fl podium-server        # should print nothing
```

If either lists a process, the sidecar lifecycle is broken — that's a bug.

## Layout

```
tauri/
├── README.md              # this file
├── .gitignore             # ignores target/, staged sidecar, generated icons
├── package.json           # optional npm entry (@tauri-apps/cli); cargo-tauri works standalone
├── prepare-sidecar.sh     # bun-compile podium-server + podium-hook, stage as externalBins,
│                          #   stage client/dist as web-dist/
├── src/
│   └── index.html         # tiny "Starting…" placeholder (window navigates to localhost after health)
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json    # externalBin: bin/podium-server, bin/podium-hook; targets: dmg/app/appimage/deb
    ├── icon-source.png    # 1024² source for `cargo tauri icon`
    ├── bin/               # staged sidecars (git-ignored)
    ├── web-dist/          # staged copy of client/dist (git-ignored), bundled as a
    │                      #   Tauri resource so podium-server can find it via --web-dist
    ├── icons/             # generated icon set (git-ignored)
    └── src/main.rs        # the shell: spawn/reuse, health-poll, vibrancy, navigate, cleanup
```

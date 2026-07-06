# Podium — Tauri desktop shell

A minimal [Tauri v2](https://v2.tauri.app) native app that bundles the Swift
`podium-server` binary as a **sidecar** and shows the live web dashboard in a
native window. This is the shell for the 1.0 pivot: one native app on macOS +
Linux, the existing Swift server as the bundled backend, the vendored React
dashboard (served *by* `podium-server`) as the UI.

The window doesn't ship any web assets of its own — `podium-server` already
serves `WebClient/dist` over HTTP, so the shell just spawns the server, waits
for `GET /api/health` to return 200, then navigates the window to
`http://127.0.0.1:<port>`.

## How it works (lifecycle)

On launch (`src-tauri/src/main.rs`, the Tauri `setup` hook):

1. If a server already answers `GET /api/health` on the target port (default
   **4820**), **reuse it** — don't spawn a second one. This mirrors the old
   SwiftUI `EmbeddedServer.resolveAndStart` behavior.
2. Otherwise spawn the `podium-server` sidecar with
   `--port <port> --data-dir <platform data dir>`. The data dir matches
   `PodiumPaths.swift` exactly, so the app reads the user's **existing DB**:
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
- **Swift toolchain** — to build the `podium-server` sidecar.
- On **Linux**, Tauri needs WebKitGTK + build deps (see the Tauri Linux
  prerequisites docs) — relevant for T1.3, not for the macOS-first path.

## Build the sidecar (required before dev/build)

The sidecar binary must be staged under `src-tauri/bin/` with the Rust target
triple suffix Tauri expects (e.g. `podium-server-aarch64-apple-darwin`). Use
the helper script:

```bash
tauri/prepare-sidecar.sh
```

It runs `swift build -c release --product podium-server` at the repo root and
copies `.build/release/podium-server` to
`src-tauri/bin/podium-server-<triple>`. Re-run it whenever the server changes.

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
tauri/prepare-sidecar.sh   # rebuild + restage the sidecar AND WebClient/dist
cd tauri
cargo tauri build
```

Produces (per `tauri.conf.json` `bundle.targets`):

- macOS: `Podium.app` + `Podium_<version>_aarch64.dmg` under
  `src-tauri/target/release/bundle/{macos,dmg}/`
- Linux: `.AppImage` + `.deb` (built inside a container — see below)

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
with the `HudWindow` material behind the window, the same material the old
SwiftUI app used (`Sources/PodiumApp/VisualEffect.swift`). The window is
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

### The `--web-dist` wire-up (bug found + fixed during T1.2 DOD)

`podium-server`'s static file resolver
(`Sources/PodiumServer/Static/StaticFileHandler.swift`) only knows two
places to find `WebClient/dist`: the `$PODIUM_WEB_DIST` env override, or
`<bundle>/Contents/Resources/WebClient/dist` — the **old SwiftUI app's**
bundle layout. A Tauri `.app` has neither: the sidecar binary lives at
`Contents/MacOS/podium-server` with no `WebClient/dist` alongside it, so
without this wiring `/` 404s and the window shows nothing but the vibrancy
blur (looks like a "glass panel with no content" bug — it's actually a
missing-assets bug).

Fixed entirely within `tauri/` (no Swift server changes — `podium-server`
already has a `--web-dist <path>` CLI flag from day one):

1. `prepare-sidecar.sh` copies `WebClient/dist` → `src-tauri/web-dist/`
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
`Sources/PodiumServerCLI` or `WebClient/dist` changed.

> macOS code signing / vibrancy / `.dmg` polish is T1.2 (done, see above).
> Linux packaging (T1.3, done) is built inside a container — see
> [`linux-build/README.md`](linux-build/README.md) for the exact
> Docker/OrbStack commands. You cannot build (or run) the Linux GUI app
> directly on macOS — Tauri Linux needs WebKitGTK + a Linux userland.

### Linux: `.AppImage` + `.deb` (T1.3)

```bash
docker build -t podium-tauri-linux-build -f tauri/linux-build/Dockerfile .
docker run --rm -v "$PWD:/src" -w /src podium-tauri-linux-build \
  bash tauri/linux-build/build-in-container.sh
```

Builds the Linux `podium-server` sidecar (same `swift:6.1` container path as
`scripts/build-linux.sh`), stages it under `src-tauri/bin/` with the Rust
target-triple naming Tauri expects, and runs `cargo tauri build --bundles
appimage,deb` — all inside the container, output lands on the host at
`tauri/src-tauri/target/release/bundle/{appimage,deb}/`.

Full details, the cross-arch (x86_64 via QEMU) note, and — since a headless
macOS host cannot render a Linux GUI window — the exact manual verification
steps on a real Linux desktop/VM: see
[`tauri/linux-build/README.md`](linux-build/README.md).

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
├── prepare-sidecar.sh     # build podium-server + stage it as an externalBin
├── linux-build/           # T1.3: reproducible Docker recipe for the Linux .AppImage/.deb
│   ├── Dockerfile         #   swift:6.1 base + Rust + webkitgtk + tauri-cli
│   ├── build-in-container.sh  # builds sidecar + runs `cargo tauri build` inside it
│   └── README.md          # exact commands, cross-arch note, manual GUI-verify steps
├── src/
│   └── index.html         # tiny "Starting…" placeholder (window navigates to localhost after health)
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json    # externalBin: bin/podium-server; targets: dmg/app/appimage/deb
    ├── icon-source.png    # 1024² source for `cargo tauri icon`
    ├── bin/               # staged sidecar (git-ignored)
    ├── web-dist/          # staged copy of WebClient/dist (git-ignored), bundled as a
    │                      #   Tauri resource so podium-server can find it via --web-dist
    ├── icons/             # generated icon set (git-ignored)
    └── src/main.rs        # the shell: spawn/reuse, health-poll, vibrancy, navigate, cleanup
```

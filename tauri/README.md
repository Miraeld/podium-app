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
cargo tauri build
```

Produces (per `tauri.conf.json` `bundle.targets`):

- macOS: `Podium.app` + a `.dmg` under
  `src-tauri/target/release/bundle/`
- Linux: `.AppImage` + `.deb` (built on/in a Linux toolchain — see T1.3)

> macOS code signing / vibrancy / `.dmg` polish is T1.2; Linux packaging is
> T1.3. This T1.1 scaffold wires the targets in config but only the macOS
> `dev` + `app`/`dmg` path is verified here.

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
├── src/
│   └── index.html         # tiny "Starting…" placeholder (window navigates to localhost after health)
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json    # externalBin: bin/podium-server; targets: dmg/app/appimage/deb
    ├── icon-source.png    # 1024² source for `cargo tauri icon`
    ├── bin/               # staged sidecar (git-ignored)
    ├── icons/             # generated icon set (git-ignored)
    └── src/main.rs        # the whole shell (~170 lines): spawn/reuse, health-poll, navigate, cleanup
```

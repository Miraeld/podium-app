# Linux build container (T1.3)

Reproducible Docker recipe that builds the Podium Tauri shell as a native
Linux app — `.AppImage` + `.deb` — with the Linux `podium-server` sidecar
baked in. Exists because Tauri Linux builds need WebKitGTK + a Linux
userland; you cannot build (or run) the Linux GUI app directly on macOS.

## Why a container, and why `swift:6.1` as the base

`scripts/build-linux.sh` already builds `podium-server` for Linux inside the
`swift:6.1` Docker image (Ubuntu 24.04 "noble" under the hood — verified via
`cat /etc/os-release` in that image). Reusing the same base means:

- the sidecar is built with the **exact toolchain** already verified for the
  tarball release path (no second, subtly-different Swift environment to
  maintain)
- Ubuntu 24.04 ships `libwebkit2gtk-4.1-dev`, which is what Tauri v2 expects
  by default (older Ubuntu 22.04 needs the `4.0` package + a compat shim)

On top of that base, `Dockerfile` layers: curl (missing in the base image),
a minimal Rust toolchain via rustup, the Tauri v2 Linux build dependencies
(webkitgtk, gtk3, librsvg, appindicator, patchelf, fuse/libfuse2 for AppImage
tooling), Node.js LTS (only needed if you go through the npm `@tauri-apps/cli`
entry point instead of the global `cargo tauri`), and `tauri-cli` itself.

## Build the image (one-time, cached after)

From the repo root:

```bash
docker build -t podium-tauri-linux-build -f tauri/linux-build/Dockerfile .
```

Takes a few minutes the first time (Rust toolchain install + `cargo install
tauri-cli`, which itself compiles ~decades of crates). Cached on rebuild
unless the Dockerfile changes.

## Run the build

```bash
docker run --rm -v "$PWD:/src" -w /src podium-tauri-linux-build \
  bash tauri/linux-build/build-in-container.sh
```

`build-in-container.sh` (runs **inside** the container):
1. `swift build -c release --product podium-server` — same command
   `build-linux.sh` uses, so the sidecar matches the release tarball build.
2. Stages the binary at `tauri/src-tauri/bin/podium-server-<rustc-host-triple>`
   (Tauri's sidecar naming convention) — e.g.
   `podium-server-aarch64-unknown-linux-gnu` or
   `podium-server-x86_64-unknown-linux-gnu`, depending on the container's
   own architecture (Docker/OrbStack on Apple Silicon defaults to
   **aarch64** containers; use `--platform linux/amd64` on `docker build`/
   `docker run` to cross-build an x86_64 image+bundle instead, at an
   emulation speed cost via QEMU).
3. Generates the icon set from `src-tauri/icon-source.png` if
   `src-tauri/icons/` is missing (icons are git-ignored build artifacts).
4. `cargo tauri build --bundles appimage,deb`.

Output lands on the **host** filesystem (bind-mounted), at:

```
tauri/src-tauri/target/release/bundle/appimage/Podium_<version>_<arch>.AppImage
tauri/src-tauri/target/release/bundle/deb/Podium_<version>_<arch>.deb
```

## Cross-arch note

The container's own CPU arch determines the sidecar + bundle arch (Tauri
bundles for the arch it's running on; there's no cross-compilation wired up
here). On an Apple Silicon Mac with OrbStack, the default is **aarch64**
Linux. To produce an **x86_64** AppImage/deb instead, force the platform on
both the image build and the run step:

```bash
docker build --platform linux/amd64 -t podium-tauri-linux-build-amd64 -f tauri/linux-build/Dockerfile .
docker run --rm --platform linux/amd64 -v "$PWD:/src" -w /src podium-tauri-linux-build-amd64 \
  bash tauri/linux-build/build-in-container.sh
```

This runs under QEMU emulation (OrbStack/Docker Desktop both support it via
`binfmt_misc`) — expect the Swift + Rust compiles to take noticeably longer.
Not attempted in the T1.3 run that produced the artifacts documented in the
task report; only the native aarch64 path was verified.

## Verifying the GUI — cannot be done on a headless macOS host

Docker on macOS has no display server, and installing Xvfb + dbus +
webkitgtk's runtime GL/audio stack inside the container to fake one is
fragile and out of scope for this task (T1.3's own DOD explicitly allows
documenting the manual step instead of faking a "works" claim). The
container build above only proves the AppImage/deb are **structurally
correct** (valid ELF, sidecar embedded, `.desktop`/AppRun present) — not that
the window renders.

**To actually verify the GUI**, on a real Linux desktop or VM with a display
(GNOME/KDE, X11 or Wayland):

```bash
# copy Podium_<version>_<arch>.AppImage to the Linux machine, then:
chmod +x Podium_*.AppImage
./Podium_*.AppImage
```

Expected: a native window titled "Podium" opens, the bundled `podium-server`
sidecar spawns (visible via `pgrep -fl podium-server`), and once
`/api/health` returns 200 the window navigates to the live dashboard reading
the real `~/.local/share/podium` (or `$XDG_DATA_HOME/podium`) database.
Closing the window should leave no orphaned `podium-server` process (same
check as the macOS README: `pgrep -fl podium-server` prints nothing after
close).

For the `.deb`: `sudo dpkg -i Podium_<version>_<arch>.deb` on a Debian/Ubuntu
desktop, then launch "Podium" from the applications menu (or run
`podium-tauri` — the binary name inside the deb, per the `.desktop` file's
`Exec=` key — from a terminal).

## What was NOT verified in this task run

- No display was available to actually launch the window and see the
  dashboard render (see above).
- Only the aarch64 (Apple Silicon container) bundle was built and confirmed
  structurally; x86_64 cross-build via QEMU is documented but not run.

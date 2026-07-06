# Linux build image for the Podium Tauri shell (T1.3).
#
# Bundles everything needed to produce a .AppImage + .deb of the Tauri app
# with the Linux `podium-server` sidecar baked in, reproducibly, on the
# dev Mac (via OrbStack/Docker) or any CI runner:
#   - Swift 6.1 toolchain (same base image as scripts/build-linux.sh, so the
#     podium-server binary is built the exact same way already verified for
#     the tarball release path)
#   - Rust (stable, via rustup) + the Tauri v2 CLI
#   - WebKitGTK 4.1 + the native build deps Tauri v2 needs on Ubuntu 24.04
#     (libwebkit2gtk-4.1-dev, libgtk-3-dev, librsvg2-dev, patchelf, appimagetk
#     deps, etc.)
#   - Node.js (only used for the optional @tauri-apps/cli npm entry point;
#     the global `cargo tauri` binary is what actually runs the build)
#
# Base: swift:6.1 is Ubuntu 24.04 (noble) — confirmed via `cat /etc/os-release`
# inside the image. That means libwebkit2gtk-4.1-dev (not the older 4.0) is
# available from apt, matching Tauri v2's default Linux webview dependency.
#
# Usage (from repo root):
#   docker build -t podium-tauri-linux-build -f tauri/linux-build/Dockerfile .
#   docker run --rm -v "$PWD:/src" -w /src podium-tauri-linux-build \
#     bash tauri/linux-build/build-in-container.sh
#
# Output: tauri/src-tauri/target/release/bundle/appimage/*.AppImage
#         tauri/src-tauri/target/release/bundle/deb/*.deb

FROM swift:6.1

ENV DEBIAN_FRONTEND=noninteractive

# --- curl (needed by the rustup installer below; not present in swift:6.1) -
RUN apt-get update -qq && apt-get install -y -qq curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# --- Rust toolchain -----------------------------------------------------
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain stable --profile minimal && \
    rustup --version && cargo --version

# --- Tauri v2 Linux build dependencies -----------------------------------
# Package list per https://v2.tauri.app/start/prerequisites/#linux (Ubuntu
# 24.04 uses the webkit2gtk-4.1 package name, not 4.0-dev as on 22.04).
RUN apt-get update -qq && apt-get install -y -qq \
      libwebkit2gtk-4.1-dev \
      libgtk-3-dev \
      librsvg2-dev \
      libssl-dev \
      libayatana-appindicator3-dev \
      libsqlite3-dev \
      patchelf \
      file \
      wget \
      pkg-config \
      build-essential \
      fuse \
      libfuse2 \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js (LTS) — optional, only for the npm-based CLI entry point ----
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y -qq nodejs && rm -rf /var/lib/apt/lists/*

# --- Tauri CLI (global cargo binary; avoids needing `npm install` at all) -
RUN cargo install tauri-cli --version "^2.0.0" --locked

WORKDIR /src

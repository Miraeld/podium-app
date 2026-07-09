# Releasing

Cut a release: `git tag vX.Y.Z && git push --tags`.

`.github/workflows/release.yml` then builds and publishes a GitHub release
for that tag: a signed-ad-hoc `Podium_X.Y.Z_<arch>.dmg` (macOS, Tauri) and
`Podium_X.Y.Z_<arch>.AppImage` + `Podium_X.Y.Z_<arch>.deb` (Linux, also
Tauri), plus auto-generated release notes.

Caveat: the DMG is ad-hoc signed only (no Apple Developer ID yet) — first
launch needs right-click → Open past Gatekeeper's "unidentified developer"
warning. In-app updates are check-only: the popup links out to the GitHub
release page for the user to download and replace manually (no self-updater yet).

Note: `scripts/build-linux.sh` also produces a
`podium-linux-<version>-<arch>.tar.gz` — that is a separate, manual
headless-server-only path (just `podium-server` + `podium-hook` +
`install-linux.sh`, no GUI shell), not something CI builds or the release
workflow uploads. Don't confuse it with the Linux release artifacts above.

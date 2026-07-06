# Releasing

Cut a release: `git tag vX.Y.Z && git push --tags`.

`.github/workflows/release.yml` then builds and publishes a GitHub release
for that tag: a signed-ad-hoc `Podium-X.Y.Z.dmg` (macOS) and a
`podium-linux-X.Y.Z-<arch>.tar.gz` (Linux), plus auto-generated release notes.

Caveat: the DMG is ad-hoc signed only (no Apple Developer ID yet) — first
launch needs right-click → Open past Gatekeeper's "unidentified developer"
warning. In-app updates are check-only: the popup links out to the GitHub
release page for the user to download and replace manually (no self-updater yet).

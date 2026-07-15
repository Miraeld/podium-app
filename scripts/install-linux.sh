#!/bin/bash
# Installs the Podium standalone server on Linux: copies the binaries (bun-
# compiled podium-server + podium-hook, N6 Node-era pivot — no Node/npm/
# node_modules needed on this machine, just glibc) + web dashboard to
# /usr/local, installs a systemd user unit, and starts it.
#
# Run this from inside the extracted tarball directory:
#   tar xzf podium-linux-<version>.tar.gz && cd podium-linux-<version> && ./install-linux.sh
#
# Zero manual steps after this (P6.1 acceptance bar): the unit starts
# podium-server with its defaults, which auto-installs the Claude Code hooks
# into ~/.claude/settings.json on first run — no separate "install hooks"
# command needed.
#
# Requires: sudo (for /usr/local), systemd with user units, loginctl
# linger enabled if you want the service to run without an active login
# session (this script does not enable linger — see the printed note).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/podium"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_NAME="podium-server.service"

[ -f "$SCRIPT_DIR/bin/podium-server" ] || { echo "✗ bin/podium-server not found — run this script from inside the extracted tarball."; exit 1; }

echo "▶ Installing binaries to $BIN_DIR (sudo)…"
sudo install -m 755 "$SCRIPT_DIR/bin/podium-server" "$BIN_DIR/podium-server"
sudo install -m 755 "$SCRIPT_DIR/bin/podium-hook" "$BIN_DIR/podium-hook"

echo "▶ Installing web dashboard to $SHARE_DIR/web (sudo)…"
sudo mkdir -p "$SHARE_DIR"
sudo rm -rf "$SHARE_DIR/web"
sudo cp -R "$SCRIPT_DIR/share/podium/web" "$SHARE_DIR/web"

echo "▶ Installing systemd user unit ($UNIT_DIR/$UNIT_NAME)…"
mkdir -p "$UNIT_DIR"
cp "$SCRIPT_DIR/$UNIT_NAME" "$UNIT_DIR/$UNIT_NAME"

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME"

echo "✓ Podium server installed and started."
echo "  Status:  systemctl --user status $UNIT_NAME"
echo "  Logs:    journalctl --user -u $UNIT_NAME -f"
echo "  Dashboard: http://localhost:4820"
echo
echo "Note: this is a --user unit, so it stops when you log out unless you"
echo "enable lingering once with:  loginctl enable-linger \$USER"

#!/bin/sh
# Builds a release `ios` and installs it for everyday use (and for other agent sessions).
#
#   scripts/install.sh            install to ~/.local (binary in ~/.local/bin, on PATH)
#   scripts/install.sh --skill    also install the ios-cli skill into ~/.claude/skills (ios skills add ios-cli)
#   PREFIX=/opt/ios-cli scripts/install.sh
#
# Re-run to update. Layout: $PREFIX/share/ios-cli/{ios, ios-cli_IOSCore.bundle}, with
# $PREFIX/bin/ios -> ../share/ios-cli/ios (the binary finds its resources next to itself).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${PREFIX:-"$HOME/.local"}
SHARE="$PREFIX/share/ios-cli"
BIN="$PREFIX/bin"

echo "Building release…"
swift build --package-path "$ROOT" -c release
PRODUCTS=$(swift build --package-path "$ROOT" -c release --show-bin-path)

mkdir -p "$SHARE" "$BIN"
cp "$PRODUCTS/ios" "$SHARE/ios.new" && mv "$SHARE/ios.new" "$SHARE/ios"
rm -rf "$SHARE/ios-cli_IOSCore.bundle"
cp -R "$PRODUCTS/ios-cli_IOSCore.bundle" "$SHARE/"
ln -sf "$SHARE/ios" "$BIN/ios"
echo "Installed $("$BIN/ios" --version) → $BIN/ios"

if [ "${1:-}" = "--skill" ]; then
    # --force replaces a copy installed by older versions of this script.
    "$BIN/ios" skills add ios-cli --force
fi

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN isn't on your PATH; add it to use \`ios\` directly." ;;
esac

#!/bin/sh
# Builds a release `ios` and installs it for everyday use (and for other agent sessions).
#
#   scripts/install.sh            install to ~/.local (binary in ~/.local/bin, on PATH)
#   scripts/install.sh --skill    also install the ios-cli skill into ~/.claude/skills (ios skills add ios-cli)
#   PREFIX=/opt/ios-cli scripts/install.sh
#   IOS_CLI_SIGN_IDENTITY=<certificate SHA-1 or name> scripts/install.sh   sign it (see below)
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
cp "$PRODUCTS/ios" "$SHARE/ios.new"
if [ -n "${IOS_CLI_SIGN_IDENTITY:-}" ]; then
    # Xcode approves an unsigned `ios` for its tool service (check, preview, create) one build at a
    # time and for 24 hours at most; a signed one is approved once, across rebuilds. The identity
    # (a certificate's name or SHA-1, from `security find-identity -v -p codesigning`) stays in your
    # environment, not in this repository.
    codesign --force --sign "$IOS_CLI_SIGN_IDENTITY" --identifier io.github.alejandrorangel.ios-cli "$SHARE/ios.new"
    echo "Signed with \$IOS_CLI_SIGN_IDENTITY."
fi
mv "$SHARE/ios.new" "$SHARE/ios"
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

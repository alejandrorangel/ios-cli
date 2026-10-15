#!/bin/sh
# Installs the latest prebuilt `ios` (macOS, Apple silicon) from GitHub Releases — no compiling.
#
#   curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh
#   curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh -s -- --skill
#
# Options: --skill (also install the ios-cli agent skill into ~/.claude/skills), --version X.Y.Z.
# Environment: PREFIX (default ~/.local), IOS_CLI_REPO (default alejandrorangel/ios-cli).
# Uses curl; falls back to the GitHub CLI if curl can't download (e.g. a private fork).
set -eu

REPO=${IOS_CLI_REPO:-alejandrorangel/ios-cli}
PREFIX=${PREFIX:-"$HOME/.local"}
ASSET=ios-cli-macos-arm64.tar.gz
VERSION=""
SKILL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skill) SKILL=1 ;;
        --version) VERSION="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "ios needs a Mac with Apple silicon (Xcode 27 runs only there)." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ios from $REPO${VERSION:+ (v$VERSION)}…"
BASE="https://github.com/$REPO/releases"
URL=${VERSION:+"$BASE/download/v$VERSION"}
URL=${URL:-"$BASE/latest/download"}
if ! { curl -fsSL "$URL/$ASSET" -o "$TMP/$ASSET" && curl -fsSL "$URL/$ASSET.sha256" -o "$TMP/$ASSET.sha256"; }; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        # Private repositories: `gh release download` without a tag picks the latest release.
        gh release download ${VERSION:+"v$VERSION"} --repo "$REPO" --pattern "$ASSET" --pattern "$ASSET.sha256" --dir "$TMP" --clobber
    else
        echo "Download failed from $URL." >&2
        exit 1
    fi
fi

(cd "$TMP" && shasum -a 256 -c "$ASSET.sha256" >/dev/null) || { echo "Checksum mismatch; not installing." >&2; exit 1; }
tar -xzf "$TMP/$ASSET" -C "$TMP"

SHARE="$PREFIX/share/ios-cli"
BIN="$PREFIX/bin"
mkdir -p "$SHARE" "$BIN"
rm -rf "$SHARE/ios-cli_IOSCore.bundle"
cp -R "$TMP/ios-cli/ios-cli_IOSCore.bundle" "$SHARE/"
cp "$TMP/ios-cli/ios" "$SHARE/ios.new" && mv "$SHARE/ios.new" "$SHARE/ios"
ln -sf "$SHARE/ios" "$BIN/ios"
echo "Installed ios $("$BIN/ios" --version) → $BIN/ios"

if [ "$SKILL" = 1 ]; then
    "$BIN/ios" skills add ios-cli --force
fi

if ! xcrun xcodebuild -version 2>/dev/null | grep -q '^Xcode 2[7-9]'; then
    echo "Note: ios needs Xcode 27 or later, selected with xcode-select." >&2
fi
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN isn't on your PATH; add it to use \`ios\` directly." ;;
esac

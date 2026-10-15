#!/bin/sh
# Builds a release and publishes it on GitHub with a prebuilt binary.
#
#   scripts/release.sh 0.2.0
#
# The version must match `version:` in Sources/ios/IOS.swift. The tree must be clean and pushed,
# so the release points at a commit everyone can see. Assets: ios-cli-macos-arm64.tar.gz
# (the binary + its resource bundle), its .sha256, and get.sh (the installer).
set -eu

VERSION=${1:?usage: scripts/release.sh <version>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

grep -q "version: \"$VERSION\"" Sources/ios/IOS.swift || { echo "Sources/ios/IOS.swift doesn't say version \"$VERSION\"." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}')" ] || { echo "Push your commits first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Tag v$VERSION already exists." >&2; exit 1; }

echo "Testing…"
swift test --quiet
echo "Building release (arm64)…"
swift build -c release --arch arm64
PRODUCTS=$(swift build -c release --arch arm64 --show-bin-path)

DIST="$ROOT/.build/dist"
rm -rf "$DIST" && mkdir -p "$DIST/ios-cli"
cp "$PRODUCTS/ios" "$DIST/ios-cli/"
cp -R "$PRODUCTS/ios-cli_IOSCore.bundle" "$DIST/ios-cli/"
"$DIST/ios-cli/ios" --version | grep -qx "$VERSION" || { echo "Built binary reports a different version." >&2; exit 1; }
ASSET=ios-cli-macos-arm64.tar.gz
(cd "$DIST" && tar -czf "$ASSET" ios-cli && shasum -a 256 "$ASSET" > "$ASSET.sha256")
cp scripts/get.sh "$DIST/get.sh"

NOTES="Prebuilt \`ios\` for macOS on Apple silicon (requires Xcode 27).

Install or update:
\`\`\`
curl -fsSL https://github.com/alejandrorangel/ios-cli/releases/latest/download/get.sh | sh -s -- --skill
\`\`\`"
gh release create "v$VERSION" "$DIST/$ASSET" "$DIST/$ASSET.sha256" "$DIST/get.sh" \
    --title "ios $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
echo "Released v$VERSION"

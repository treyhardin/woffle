#!/usr/bin/env bash
#
# Builds a universal, release-configured Woffle, packages it as a .dmg,
# and generates the EdDSA-signed Sparkle appcast — ready to upload to a GitHub Release.
#
# Usage:  scripts/release.sh
#
# Prerequisites:
#   - xcodegen, and the Sparkle signing key in your Keychain (scripts/generate-keys.sh).
#   - For a *notarized* (no Gatekeeper warning) build, see the NOTARIZE note at the bottom.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Woffle"
SCHEME="FontManager"
DIST="dist"
ARCHIVE="$DIST/FontManager.xcarchive"
STAGING="$DIST/staging"
UPDATES="$DIST/updates"
REPO="treyhardin/woffle"

VERSION="$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')"
DMG="$UPDATES/Woffle-$VERSION.dmg"

echo "▸ Releasing Woffle $VERSION"
rm -rf "$DIST"
mkdir -p "$STAGING" "$UPDATES"

echo "▸ Regenerating project"
xcodegen generate >/dev/null

echo "▸ Archiving (universal: arm64 + x86_64, ad-hoc signed)"
xcodebuild archive \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  -quiet

APP_PATH="$ARCHIVE/Products/Applications/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "✗ Build did not produce $APP_PATH"; exit 1; }

echo "▸ Verifying universal binary"
lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME" || true

echo "▸ Building .dmg"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "▸ Generating signed appcast"
GENERATE_APPCAST="$(find ~/Library/Developer/Xcode/DerivedData/FontManager-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast 2>/dev/null | head -1)"
[ -n "$GENERATE_APPCAST" ] || { echo "✗ Could not find Sparkle's generate_appcast (build once to fetch Sparkle)"; exit 1; }
"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  "$UPDATES"

echo
echo "✓ Done. Artifacts in $UPDATES:"
ls -1 "$UPDATES"
echo
echo "Next — publish the GitHub Release (review first):"
echo "  gh release create v$VERSION \\"
echo "    \"$DMG\" \\"
echo "    \"$UPDATES/appcast.xml\" \\"
echo "    --title \"Woffle $VERSION\" --notes \"…release notes…\""
echo
echo "NOTARIZE (optional, removes the Gatekeeper warning — needs an Apple Developer ID):"
echo "  1) Sign with Developer ID instead of \"-\":  CODE_SIGN_IDENTITY=\"Developer ID Application: <NAME> (<TEAMID>)\" + --options runtime"
echo "  2) xcrun notarytool submit \"$DMG\" --keychain-profile <profile> --wait"
echo "  3) xcrun stapler staple \"$DMG\"  (then regenerate the appcast)"

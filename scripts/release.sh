#!/usr/bin/env bash
# Dictabar public release helper.
#
# Usage:
#   ./scripts/release.sh              # build, notarize, sign update, write appcast
#   ./scripts/release.sh --github     # also create/update GitHub release
#
# Optional:
#   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
#   NOTARY_PROFILE="Dictabar Notary"
#   SKIP_BUILD=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GITHUB=0
for arg in "$@"; do
  case "$arg" in
    --github) GITHUB=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

PBX="Dictabar.xcodeproj/project.pbxproj"
VERSION=$(grep -m1 'MARKETING_VERSION' "$PBX" | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBX" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);/\1/')
echo "→ Dictabar $VERSION ($BUILD)"

APP_SRC="build/DerivedData/Build/Products/Release/Dictabar.app"
ZIP="build/Dictabar-${VERSION}.zip"
APPCAST="build/appcast.xml"
NOTARY_PROFILE="${NOTARY_PROFILE:-Dictabar Notary}"
UPDATE_REPO="promantos/dictabar-updates"
DEVELOPER_ID=$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' \
  | head -n 1)

if [[ -z "$DEVELOPER_ID" ]]; then
  echo "Missing Developer ID Application certificate; refusing to build a public release." >&2
  exit 1
fi
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "→ Building Release…"
  xcodebuild \
    -project Dictabar.xcodeproj \
    -scheme Dictabar \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -disableAutomaticPackageResolution \
    -skipPackagePluginValidation \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "Missing app at $APP_SRC" >&2
  exit 1
fi

# Xcode's ordinary build re-signs Sparkle.framework but not its nested helpers.
# Sign them inside-out as required by Sparkle, then restore the outer app seal.
SPARKLE_FRAMEWORK="$APP_SRC/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "→ Signing Sparkle helpers…"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    "$SPARKLE_FRAMEWORK"
  codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
    --entitlements Dictabar/Dictabar.entitlements \
    "$APP_SRC"
fi

SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")
if [[ "$SHORT" != "$VERSION" ]]; then
  echo "Version mismatch pbx=$VERSION app=$SHORT" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_SRC"
SIGNING_INFO=$(codesign -d --verbose=4 "$APP_SRC" 2>&1)
if ! grep 'runtime' <<<"$SIGNING_INFO" >/dev/null; then
  echo "Hardened Runtime is missing." >&2
  exit 1
fi
if ! grep 'Timestamp=' <<<"$SIGNING_INFO" >/dev/null; then
  echo "Secure timestamp is missing." >&2
  exit 1
fi
if codesign -d --entitlements :- "$APP_SRC" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "Release contains get-task-allow." >&2
  exit 1
fi

echo "→ Zipping for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_SRC" "$ZIP"

echo "→ Notarizing…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_SRC"
xcrun stapler validate "$APP_SRC"
spctl --assess --type execute --verbose=4 "$APP_SRC"

echo "→ Repacking stapled app…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_SRC" "$ZIP"
LENGTH=$(stat -f%z "$ZIP")
PUBDATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')
SPARKLE_BIN="${SPARKLE_BIN:-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "Missing Sparkle sign_update at $SPARKLE_BIN/sign_update" >&2
  exit 1
fi
SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP" | sed -E 's/ length="[0-9]+"//')

echo "→ Writing appcast…"
sed \
  -e "s/__VERSION__/${VERSION}/g" \
  -e "s/__BUILD__/${BUILD}/g" \
  -e "s/__LENGTH__/${LENGTH}/g" \
  -e "s/__PUBDATE__/${PUBDATE}/g" \
  -e "s|__SIGNATURE__|${SIGNATURE}|g" \
  scripts/appcast.template.xml > "$APPCAST"
cp "$APPCAST" appcast.xml

echo "  zip:     $ZIP ($LENGTH bytes)"
echo "  appcast: $APPCAST"
echo "  feed:    https://raw.githubusercontent.com/${UPDATE_REPO}/main/appcast.xml"
echo "  package: https://github.com/${UPDATE_REPO}/releases/download/v${VERSION}/Dictabar-${VERSION}.zip"

if [[ "$GITHUB" == "1" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh not found" >&2
    exit 1
  fi
  release_tag="v${VERSION}"
  if gh release view "${release_tag}" --repo "$UPDATE_REPO" >/dev/null 2>&1; then
    echo "-> Release ${release_tag} exists - uploading asset"
    gh release upload "${release_tag}" "$ZIP" --repo "$UPDATE_REPO" --clobber
  else
    echo "-> Creating GitHub release ${release_tag}"
    gh release create "${release_tag}" "$ZIP" \
      --repo "$UPDATE_REPO" \
      --target main \
      --title "Dictabar ${VERSION}" \
      --prerelease \
      --notes "Dictabar ${VERSION} (build ${BUILD}).

- Signed with Developer ID and notarized by Apple
- Automatic secure updates via Sparkle 2
- Open-source under GPL-3.0
- Installable directly or with Homebrew
- Local and bring-your-own-key speech recognition"
  fi
fi

echo "Done. Developer ID signature, notarization, staple and Gatekeeper assessment passed."

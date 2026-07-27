#!/usr/bin/env bash
# FlowDictate public release helper.
#
# Usage:
#   ./scripts/release.sh              # build, zip, write appcast, optional gh release
#   ./scripts/release.sh --upload     # also upload zip+appcast to Cloudflare R2
#   ./scripts/release.sh --github     # create GitHub release with zip
#
# Required for --upload:
#   CLOUDFLARE_ACCOUNT_ID
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_BUCKET          (default: flowdictate-updates)
#   UPDATE_PUBLIC_BASE (default: https://updates.flowdictate.app)
#
# Optional:
#   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
#   NOTARY_PROFILE=FlowDictate-notary (required for public upload)
#   SKIP_BUILD=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPLOAD=0
GITHUB=0
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=1 ;;
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

PBX="FlowDictate.xcodeproj/project.pbxproj"
VERSION=$(grep -m1 'MARKETING_VERSION' "$PBX" | sed -E 's/.*MARKETING_VERSION = ([^;]+);/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PBX" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);/\1/')
echo "→ FlowDictate $VERSION ($BUILD)"

APP_SRC="build/DerivedData/Build/Products/Release/FlowDictate.app"
ZIP="build/FlowDictate-${VERSION}.zip"
APPCAST="build/appcast.xml"
R2_BUCKET="${R2_BUCKET:-flowdictate-updates}"
UPDATE_PUBLIC_BASE="${UPDATE_PUBLIC_BASE:-https://updates.flowdictate.app}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEVELOPER_ID=$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' \
  | head -n 1)

if [[ -z "$DEVELOPER_ID" ]]; then
  echo "Missing Developer ID Application certificate; refusing to build a public release." >&2
  exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set NOTARY_PROFILE to a notarytool Keychain profile; notarization is mandatory." >&2
  exit 1
fi

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "→ Building Release…"
  xcodebuild \
    -project FlowDictate.xcodeproj \
    -scheme FlowDictate \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
    build
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "Missing app at $APP_SRC" >&2
  exit 1
fi

SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")
if [[ "$SHORT" != "$VERSION" ]]; then
  echo "Version mismatch pbx=$VERSION app=$SHORT" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_SRC"
if ! codesign -d --verbose=4 "$APP_SRC" 2>&1 | grep -q 'runtime'; then
  echo "Hardened Runtime is missing." >&2
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

echo "→ Writing appcast…"
sed \
  -e "s/__VERSION__/${VERSION}/g" \
  -e "s/__BUILD__/${BUILD}/g" \
  -e "s/__LENGTH__/${LENGTH}/g" \
  -e "s/__PUBDATE__/${PUBDATE}/g" \
  -e "s|https://updates.flowdictate.app|${UPDATE_PUBLIC_BASE}|g" \
  scripts/appcast.template.xml > "$APPCAST"

echo "  zip:     $ZIP ($LENGTH bytes)"
echo "  appcast: $APPCAST"
echo "  feed:    ${UPDATE_PUBLIC_BASE}/appcast.xml"
echo "  package: ${UPDATE_PUBLIC_BASE}/FlowDictate-${VERSION}.zip"

if [[ "$UPLOAD" == "1" ]]; then
  : "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID}"
  : "${R2_ACCESS_KEY_ID:?Set R2_ACCESS_KEY_ID}"
  : "${R2_SECRET_ACCESS_KEY:?Set R2_SECRET_ACCESS_KEY}"

  if ! command -v aws >/dev/null 2>&1; then
    echo "Install AWS CLI (R2 S3-compatible): brew install awscli" >&2
    exit 1
  fi

  ENDPOINT="https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION=auto

  echo "→ Upload to R2 bucket $R2_BUCKET…"
  aws s3 cp "$ZIP" "s3://${R2_BUCKET}/FlowDictate-${VERSION}.zip" \
    --endpoint-url "$ENDPOINT" \
    --content-type application/zip
  aws s3 cp "$APPCAST" "s3://${R2_BUCKET}/appcast.xml" \
    --endpoint-url "$ENDPOINT" \
    --content-type application/xml
  echo "  public: ${UPDATE_PUBLIC_BASE}/appcast.xml"
fi

if [[ "$GITHUB" == "1" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh not found" >&2
    exit 1
  fi
  release_tag="v${VERSION}"
  if gh release view "${release_tag}" >/dev/null 2>&1; then
    echo "-> Release ${release_tag} exists - uploading asset"
    gh release upload "${release_tag}" "$ZIP" --clobber
  else
    echo "-> Creating GitHub release ${release_tag}"
    gh release create "${release_tag}" "$ZIP" \
      --title "FlowDictate ${VERSION}" \
      --notes "FlowDictate ${VERSION} (build ${BUILD}).

Download the zip, move FlowDictate.app to Applications.

Updates feed (after Cloudflare upload): ${UPDATE_PUBLIC_BASE}/appcast.xml

## 0.6.7 highlights
- Reliable provider retries with quota, balance, model, timeout and network diagnostics
- Recover and retry the last failed dictation
- Streamed uploads and bounded responses for lower memory use
- Per-device microphone capture without changing the macOS default input
- Safer text insertion, clipboard restoration and Unicode typing fallback
- Lower idle CPU usage, bounded logs and debug recordings
- Developer ID, notarization and Gatekeeper release checks"
  fi
fi

echo "Done. Developer ID signature, notarization, staple and Gatekeeper assessment passed."

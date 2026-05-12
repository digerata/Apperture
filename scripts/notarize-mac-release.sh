#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Apperture.xcodeproj}"
SCHEME="${SCHEME:-AppertureMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${APPLE_TEAM_ID:-VY76D5S364}"
PRODUCT_NAME="${PRODUCT_NAME:-Apperture}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.landmk1.apperture}"
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://runapperture.com/releases/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-D/FhR/NzyAxCqIHM/cdEYAdMyn1G8pulIwPP5fQv7Dg=}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/mac-release}"
ARCHIVE_PATH="$BUILD_ROOT/$PRODUCT_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
ARTIFACTS_PATH="$BUILD_ROOT/artifacts"
DMG_STAGING_PATH="$BUILD_ROOT/dmg-staging"
EXPORT_OPTIONS_PATH="$BUILD_ROOT/ExportOptions.plist"
APP_PATH="$EXPORT_PATH/$PRODUCT_NAME.app"
NOTARY_UPLOAD_ZIP="$ARTIFACTS_PATH/$PRODUCT_NAME-notary-upload.zip"
DMG_PATH=""

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' is not available" >&2
    exit 1
  fi
}

submit_for_notarization() {
  local path="$1"

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "Submitting $(basename "$path") for notarization..."
    xcrun notarytool submit "$path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    return
  fi

  local apple_id="${NOTARY_APPLE_ID:-${APPLE_ID:-}}"
  local password="${NOTARY_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"

  if [[ -z "$apple_id" || -z "$password" || -z "$TEAM_ID" ]]; then
    cat >&2 <<EOF
error: missing notarization credentials.
Provide either NOTARY_KEYCHAIN_PROFILE, or NOTARY_APPLE_ID/APPLE_ID,
NOTARY_PASSWORD/APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID.
EOF
    exit 1
  fi

  echo "Submitting $(basename "$path") for notarization..."
  xcrun notarytool submit "$path" \
    --apple-id "$apple_id" \
    --password "$password" \
    --team-id "$TEAM_ID" \
    --wait
}

expected_version_from_release_tag() {
  local tag="${RELEASE_TAG:-}"
  [[ -n "$tag" ]] || return 0

  tag="${tag#refs/tags/}"
  tag="${tag#mac-v}"
  tag="${tag#v}"

  if [[ ! "$tag" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    cat >&2 <<EOF
error: RELEASE_TAG must look like v1.2.3 or mac-v1.2.3.
Got: ${RELEASE_TAG}
EOF
    exit 1
  fi

  echo "$tag"
}

require_tool xcodebuild
require_tool xcrun
require_tool ditto
require_tool hdiutil

if [[ "${SKIP_SIGNING_IDENTITY_CHECK:-0}" != "1" ]]; then
  echo "Checking for Developer ID Application signing identity..."
  if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    cat >&2 <<EOF
error: no Developer ID Application signing identity with private key was found.
Install/export a Developer ID Application certificate that includes its private key,
or import it into the CI keychain before running this script.
EOF
    exit 1
  fi
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$EXPORT_PATH" "$ARTIFACTS_PATH" "$DMG_STAGING_PATH"

cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$DEVELOPER_ID_IDENTITY</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "Archiving $SCHEME..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"

echo "Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app at $APP_PATH" >&2
  exit 1
fi

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" || true

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
EXPECTED_APP_VERSION="$(expected_version_from_release_tag)"
if [[ -n "$EXPECTED_APP_VERSION" && "$APP_VERSION" != "$EXPECTED_APP_VERSION" ]]; then
  cat >&2 <<EOF
error: release tag version does not match the built app version.
Release tag: ${RELEASE_TAG}
Expected app version: ${EXPECTED_APP_VERSION}
Built app version: ${APP_VERSION}
Update CFBundleShortVersionString before publishing this release.
EOF
  exit 1
fi

DMG_BASENAME="${PRODUCT_NAME}-${APP_VERSION}"
DMG_PATH="$ARTIFACTS_PATH/$DMG_BASENAME.dmg"

if [[ "${SKIP_NOTARIZATION:-0}" == "1" ]]; then
  echo "SKIP_NOTARIZATION=1, skipping notarytool and stapling."
else
  echo "Creating app ZIP for notarization..."
  ditto -c -k --keepParent "$APP_PATH" "$NOTARY_UPLOAD_ZIP"
  submit_for_notarization "$NOTARY_UPLOAD_ZIP"

  echo "Stapling notarization ticket to app..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
fi

echo "Creating disk image..."
rm -f "$DMG_PATH"
rm -rf "$DMG_STAGING_PATH"
mkdir -p "$DMG_STAGING_PATH"
ditto "$APP_PATH" "$DMG_STAGING_PATH/$PRODUCT_NAME.app"
ln -s /Applications "$DMG_STAGING_PATH/Applications"
hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$DMG_STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Signing disk image..."
codesign --force --sign "$DEVELOPER_ID_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  submit_for_notarization "$DMG_PATH"
  echo "Stapling notarization ticket to disk image..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Writing SHA-256 checksum..."
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

echo "Release artifact:"
echo "$DMG_PATH"
echo "$DMG_PATH.sha256"

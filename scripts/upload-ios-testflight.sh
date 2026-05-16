#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Apperture.xcodeproj}"
SCHEME="${SCHEME:-AppertureiOS}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${APPLE_TEAM_ID:-VY76D5S364}"
PRODUCT_NAME="${PRODUCT_NAME:-Apperture}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.landmk1.apperture}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/ios-testflight}"
ARCHIVE_PATH="$BUILD_ROOT/$PRODUCT_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
EXPORT_OPTIONS_PATH="$BUILD_ROOT/ExportOptions.plist"
UPLOAD_LOG_PATH="$BUILD_ROOT/upload.log"
API_KEY_DIR="$HOME/.appstoreconnect/private_keys"
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
IOS_PROFILE_SPECIFIER="${IOS_PROVISIONING_PROFILE_SPECIFIER:-}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' is not available" >&2
    exit 1
  fi
}

configure_app_store_connect_key() {
  if [[ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" || -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    cat >&2 <<EOF
error: missing App Store Connect API key details.
Set APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID.
EOF
    exit 1
  fi

  if [[ -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
    mkdir -p "$API_KEY_DIR"
    printf "%s" "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 -D > "$API_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
    chmod 600 "$API_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  fi

  if [[ ! -f "$API_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8" ]]; then
    cat >&2 <<EOF
error: App Store Connect API key file was not found.
Expected: $API_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8
Provide APP_STORE_CONNECT_API_KEY_BASE64 in CI or install the key locally.
EOF
    exit 1
  fi
}

install_provisioning_profile() {
  [[ -n "${IOS_PROVISIONING_PROFILE_BASE64:-}" ]] || return 0

  mkdir -p "$PROFILES_DIR"
  local profile_path="$BUILD_ROOT/ios-app-store.mobileprovision"
  local profile_plist="$BUILD_ROOT/ios-app-store-profile.plist"

  printf "%s" "$IOS_PROVISIONING_PROFILE_BASE64" | base64 -D > "$profile_path"
  security cms -D -i "$profile_path" > "$profile_plist"

  local uuid
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$profile_plist")"
  if [[ -z "$IOS_PROFILE_SPECIFIER" ]]; then
    IOS_PROFILE_SPECIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
  fi

  cp "$profile_path" "$PROFILES_DIR/$uuid.mobileprovision"
  echo "Installed provisioning profile: $IOS_PROFILE_SPECIFIER ($uuid)"
}

require_tool xcodebuild
require_tool xcrun
require_tool security

configure_app_store_connect_key

rm -rf "$BUILD_ROOT"
mkdir -p "$EXPORT_PATH"
install_provisioning_profile

if [[ -n "$IOS_PROFILE_SPECIFIER" ]]; then
  cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$APP_BUNDLE_ID</key>
		<string>$IOS_PROFILE_SPECIFIER</string>
	</dict>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
else
  cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
EOF
fi

XCODE_AUTH_ARGS=(
  -authenticationKeyPath "$API_KEY_DIR/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID"
)

ARCHIVE_SIGNING_ARGS=(
  CODE_SIGN_STYLE=Automatic
  CODE_SIGN_IDENTITY="Apple Development"
)

if [[ -n "$IOS_PROFILE_SPECIFIER" ]]; then
  ARCHIVE_SIGNING_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    PROVISIONING_PROFILE_SPECIFIER="$IOS_PROFILE_SPECIFIER"
  )
fi

echo "Archiving $SCHEME for iOS..."
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH_ARGS[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  "${ARCHIVE_SIGNING_ARGS[@]}" \
  PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"

echo "Exporting IPA..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
  -allowProvisioningUpdates \
  "${XCODE_AUTH_ARGS[@]}"

IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name "*.ipa" -type f -print -quit)"
if [[ -z "$IPA_PATH" ]]; then
  echo "error: no IPA was exported to $EXPORT_PATH" >&2
  exit 1
fi

echo "Uploading IPA to App Store Connect..."
set +e
xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID" \
  2>&1 | tee "$UPLOAD_LOG_PATH"
upload_status=${PIPESTATUS[0]}
set -e

if [[ "$upload_status" -ne 0 ]] || grep -Eiq "UPLOAD FAILED|Failed to upload package|Validation failed|STATE_ERROR|ERROR:" "$UPLOAD_LOG_PATH"; then
  echo "error: App Store Connect upload failed. See log above." >&2
  exit 1
fi

echo "Uploaded TestFlight build:"
echo "$IPA_PATH"

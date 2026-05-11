# Mac Notarized Distribution

Apperture Mac is distributed outside the Mac App Store, so release builds need Developer ID signing, Hardened Runtime, notarization, and stapling before publishing to the website.

Apple's current command-line flow uses `notarytool` and `stapler`. The older `altool` notarization path is no longer accepted.

## One-Time Apple Setup

1. In Apple Developer, create or download a **Developer ID Application** certificate for team `VY76D5S364`.
2. Export the certificate plus private key from Keychain Access as a `.p12`.
3. Create an app-specific password for the Apple ID used for notarization.
4. Add these GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer Team ID, currently `VY76D5S364`. |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization. |
| `NOTARY_PASSWORD` | App-specific password for `NOTARY_APPLE_ID`. |
| `DEVELOPER_ID_APPLICATION_CERT_BASE64` | Base64-encoded `.p12` certificate export. |
| `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` | Password used when exporting the `.p12`. |
| `RELEASE_KEYCHAIN_PASSWORD` | Random password for the temporary CI keychain. |
| `SPARKLE_PRIVATE_ED_KEY` | Optional Sparkle EdDSA private key for generating `appcast.xml`. |
| `SPARKLE_PUBLIC_ED_KEY` | Optional alternative to storing the public key as a variable. |
| `SPARKLE_FEED_URL` | Optional alternative to storing the feed URL as a variable. |
| `SPARKLE_DOWNLOAD_URL_PREFIX` | Optional alternative to storing the download URL prefix as a variable. |

Add these GitHub Actions variables:

| Variable | Value |
| --- | --- |
| `SPARKLE_FEED_URL` | Public appcast URL, defaulting to `https://runaperture.com/releases/appcast.xml`. |
| `SPARKLE_PUBLIC_ED_KEY` | Public EdDSA key printed by Sparkle `generate_keys`. |
| `SPARKLE_DOWNLOAD_URL_PREFIX` | Public folder where the DMG will be hosted, defaulting to `https://runaperture.com/releases`. |

Encode the `.p12` for GitHub:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

## GitHub Actions Release

Run **Mac Release** manually from GitHub Actions, or push a tag matching `mac-v*` or `v*`.

The workflow:

1. Imports the Developer ID certificate into a temporary keychain.
2. Archives `AppertureMac` in Release configuration.
3. Exports a Developer ID-signed `Apperture.app`.
4. Submits the app ZIP to Apple notarization.
5. Staples the app.
6. Creates a versioned DMG, for example `Apperture-0.1.0.dmg`, with an `/Applications` drag shortcut.
7. Signs, notarizes, and staples the DMG.
8. Writes a SHA-256 checksum next to the DMG.
9. Generates a Sparkle appcast if `SPARKLE_PRIVATE_ED_KEY`, `SPARKLE_PUBLIC_ED_KEY`, and `SPARKLE_FEED_URL` are configured.
10. Uploads the DMG, checksum, and appcast as workflow artifacts and attaches them to tagged GitHub releases.

## Local Release

If your Developer ID certificate is already installed locally:

```sh
export APPLE_TEAM_ID=VY76D5S364
export NOTARY_APPLE_ID="you@example.com"
export NOTARY_PASSWORD="app-specific-password"
scripts/notarize-mac-release.sh
```

The final website artifact is:

```text
build/mac-release/artifacts/Apperture-<version>.dmg
build/mac-release/artifacts/Apperture-<version>.dmg.sha256
```

If Sparkle signing is configured, the appcast is:

```text
build/mac-release/artifacts/sparkle/appcast.xml
```

## Sparkle Updates

Sparkle is linked into the Mac app but stays disabled until the release build has a real `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY`. This avoids accidentally shipping a broken updater while the website URL is still provisional.

One-time Sparkle key setup:

1. Build once so Xcode resolves the Sparkle Swift package.
2. Find Sparkle's tools under DerivedData, typically:

   ```text
   ~/Library/Developer/Xcode/DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/
   ```

3. Run:

   ```sh
   ./generate_keys
   ```

4. Save the printed public key as GitHub Actions variable or secret `SPARKLE_PUBLIC_ED_KEY`.
5. Export or copy the private key into GitHub secret `SPARKLE_PRIVATE_ED_KEY`.
6. Set `SPARKLE_FEED_URL` to the final HTTPS URL where `appcast.xml` will live.
7. Set `SPARKLE_DOWNLOAD_URL_PREFIX` to the final HTTPS folder where the DMG will live.

The release script passes `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` into the archived app. If `SPARKLE_PRIVATE_ED_KEY` is available, it runs Sparkle's `generate_appcast` and signs the update feed.

For a local packaging test without notarization:

```sh
SKIP_NOTARIZATION=1 scripts/notarize-mac-release.sh
```

That still requires Developer ID signing unless you override signing for local experiments.

## Verification

Before publishing, verify the artifact:

```sh
spctl --assess --type open --context context:primary-signature -v build/mac-release/artifacts/Apperture.dmg
hdiutil attach build/mac-release/artifacts/Apperture.dmg
spctl --assess --type execute -v /Volumes/Apperture/Apperture.app
hdiutil detach /Volumes/Apperture
```

The app target already has Hardened Runtime enabled, which Apple requires for Developer ID notarization.

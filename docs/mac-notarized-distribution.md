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
6. Creates `Apperture.dmg`.
7. Notarizes and staples the DMG.
8. Uploads the DMG as a workflow artifact and attaches it to tagged GitHub releases.

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
build/mac-release/artifacts/Apperture.dmg
```

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

<wizard-report>
# PostHog post-wizard report

The wizard has completed a deep integration of PostHog analytics into the Apperture project (Mac + iOS). PostHog is initialized in both app entry points using environment variables read from the Xcode scheme. Thirteen events are now tracked across the two key model files covering the full pairing lifecycle, screen mirroring sessions, and client connectivity.

## Changes summary

| File | Change |
|------|--------|
| `Apperture.xcodeproj/project.pbxproj` | Added `posthog-ios` (v3.58.3) as an SPM package dependency for both the Mac and iOS targets |
| `Apperture.xcodeproj/xcshareddata/xcschemes/AppertureMac.xcscheme` | Created shared scheme with `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` environment variable placeholders |
| `Apperture.xcodeproj/xcshareddata/xcschemes/AppertureiOS.xcscheme` | Created shared scheme with `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` environment variable placeholders |
| `Sources/Mac/AppertureMacApp.swift` | Added `PostHogEnv` enum and PostHog SDK initialization in `applicationDidFinishLaunching` |
| `Sources/iOS/AppertureiOSApp.swift` | Added PostHog SDK initialization in `application(_:didFinishLaunchingWithOptions:)` |
| `Sources/Mac/HostModel.swift` | Added event capture for pairing, mirroring, and client connection events |
| `Sources/iOS/iOSPairingManager.swift` | Added event capture for iOS-side pairing events |

## Events instrumented

| Event | Description | File |
|-------|-------------|------|
| `pairing_code_created` | Mac host user creates a new QR pairing code | `Sources/Mac/HostModel.swift` |
| `pairing_approved` | Mac host user approves a pending pairing request | `Sources/Mac/HostModel.swift` |
| `pairing_rejected` | Mac host user rejects a pending pairing request | `Sources/Mac/HostModel.swift` |
| `pairing_revoked` | Mac host user revokes a previously paired device | `Sources/Mac/HostModel.swift` |
| `mirroring_started` | Mac host starts a live screen mirroring session | `Sources/Mac/HostModel.swift` |
| `mirroring_stopped` | Mac host stops an active mirroring session | `Sources/Mac/HostModel.swift` |
| `mirroring_failed` | Mac host fails to start or maintain a mirroring session | `Sources/Mac/HostModel.swift` |
| `client_connected` | An iPhone client connects to the Mac frame server | `Sources/Mac/HostModel.swift` |
| `client_disconnected` | An iPhone client disconnects from the Mac frame server | `Sources/Mac/HostModel.swift` |
| `screen_recording_permission_requested` | Mac host user requests screen recording permission | `Sources/Mac/HostModel.swift` |
| `ios_pairing_initiated` | iOS user scans a QR code and initiates a pairing request | `Sources/iOS/iOSPairingManager.swift` |
| `ios_pairing_accepted` | iOS device successfully completes pairing | `Sources/iOS/iOSPairingManager.swift` |
| `ios_device_forgotten` | iOS user removes a previously paired Mac | `Sources/iOS/iOSPairingManager.swift` |

## Setup required

Before running, fill in the real PostHog token in each Xcode scheme's Run environment variables (the placeholders currently read `YOUR_POSTHOG_PROJECT_TOKEN` and `YOUR_POSTHOG_HOST`). Find your token in [PostHog project settings](/settings/project).

## Next steps

We've built some insights and a dashboard for you to keep an eye on user behavior, based on the events we just instrumented:

- [Analytics basics dashboard](/dashboard/1590826)
- [Pairing Conversion Funnel](/insights/DOSQNwXJ) — conversion rate from code created → approved (churn signal: low approval rate)
- [Mirroring Sessions Started](/insights/iSNIk5an) — daily trend of mirroring sessions
- [Client Connections vs Disconnections](/insights/gHMO7kZu) — connection churn over time
- [Pairing Activity](/insights/aawqSGkC) — codes created, approved, and rejected side-by-side
- [iOS Pairing Flow](/insights/HFFe6t73) — initiated vs accepted on the iOS side

### Agent skill

We've left an agent skill folder in your project at `.claude/skills/integration-swift/`. You can use this context for further agent development when using Claude Code. This will help ensure the model provides the most up-to-date approaches for integrating PostHog.

</wizard-report>

---
name: apperture-xcode-runner
description: Build, test, install, launch, or relaunch Xcode apps while reporting build/run activity to Apperture so the Mac host and iOS viewer can show status and select the launched app or simulator.
---

# Apperture Xcode Runner

Use this skill when working on an Xcode project and the user wants the app built, tested, installed, launched, relaunched, or made visible through Apperture.

## Event Contract

Apperture watches JSON files in:

`~/Library/Application Support/Apperture/AgentEvents`

Prefer the bundled helper:

```bash
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py buildStarted --scheme MyApp --destination "platform=iOS Simulator,name=iPhone 16"
```

If the sandbox blocks writing to Application Support, request approval and rerun the helper; do not silently skip event emission.

Important event kinds:

- `buildStarted`, `buildFinished`
- `testStarted`, `testFinished`
- `simulatorBooted`
- `appInstalled`
- `appLaunched`
- `appRunFailed`

Common fields:

- `scheme`: Xcode scheme.
- `destination`: xcodebuild destination string.
- `platform`: `simulator`, `ios-device`, or `macos`.
- `bundleID`: launched app bundle identifier.
- `appPath`: path to a built `.app`.
- `pid`: process id for a launched macOS app.
- `status`: `started`, `succeeded`, or `failed`.
- `message`: short user-facing status or error.
- `warningCount`, `errorCount`: build issue counts when available.
- `resultBundlePath`, `resultStreamPath`: paths from xcodebuild when used.

## Workflow

1. Emit `buildStarted` before running `xcodebuild`.
2. Build or test with explicit output paths when possible:
   - `-resultBundlePath <path>.xcresult`
   - `-resultStreamPath <path>.json`
   - `-derivedDataPath <workspace-local DerivedData path>` when appropriate.
3. Emit `buildFinished` or `testFinished` with `status`, `message`, and issue counts.
4. If launching on a simulator, boot the simulator, install the app, launch with `xcrun simctl launch`, then emit `appLaunched` with `platform=simulator`, `simulatorUDID`, and `bundleID`.
5. If launching a macOS app, start the built app, capture its process id, then emit `appLaunched` with `platform=macos`, `appPath`, and `pid`.
6. If launch fails after a successful build, emit `appRunFailed` with the failure message.

Keep messages concise; Apperture shows them in compact Mac and iOS status surfaces.

## Examples

macOS launch:

```bash
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py buildStarted --scheme MyMacApp --platform macos
xcodebuild -scheme MyMacApp -destination generic/platform=macOS build
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py buildFinished --scheme MyMacApp --platform macos --status succeeded --message "Build finished"
open -n DerivedData/Build/Products/Debug/MyMacApp.app
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py appLaunched --scheme MyMacApp --platform macos --app-path DerivedData/Build/Products/Debug/MyMacApp.app --message "App launched"
```

Simulator launch:

```bash
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py buildStarted --scheme MyApp --platform simulator --destination "platform=iOS Simulator,name=iPhone 16"
xcodebuild -scheme MyApp -destination "platform=iOS Simulator,name=iPhone 16" build
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py buildFinished --scheme MyApp --platform simulator --status succeeded --message "Build finished"
xcrun simctl bootstatus booted
xcrun simctl install booted DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app
xcrun simctl launch booted com.example.MyApp
python3 AgentSkills/apperture-xcode-runner/scripts/apperture_event.py appLaunched --scheme MyApp --platform simulator --bundle-id com.example.MyApp --message "App launched in Simulator"
```

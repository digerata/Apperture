# Xcode Agent Integration

## Goal

Make Apperture a reliable target for coding agents working on Xcode projects.

After an agent finishes coding, testing, and building, it should leave the app
running in a viewable place and give Apperture enough machine-readable context
to show build status, build messages, and the active app or simulator target in
the iOS viewer.

This should work best for agent-driven workflows, while still leaving room for
best-effort detection of manual Xcode GUI builds and runs.

## Core Idea

Use two cooperating pieces:

1. An Apperture-side Xcode integration that can receive or discover build/run
   events.
2. A distributable agent skill that teaches agents how to build, launch,
   relaunch, and notify Apperture consistently.

The skill is the agent-side contract. The Mac app is the source of truth for
what the iPhone sees.

## Why A Skill Makes Sense

This is exactly the kind of workflow a skill should capture:

- It is procedural and easy for a general coding agent to forget.
- It involves fragile Xcode command details.
- It needs consistent post-task behavior, not just a successful build.
- It should work across many user projects, not only this repository.

The skill should not replace product behavior. It should instruct agents to use
an Apperture command or API that the product owns.

## Proposed Agent Contract

Agents should follow this lifecycle when working on an Xcode project:

1. Discover the project, workspace, schemes, and likely run destination.
2. Build and test using observable Xcode outputs.
3. Start or restart the app in Simulator or on macOS after the build succeeds.
4. Notify Apperture where the result bundle or result stream lives.
5. Notify Apperture what app was launched and where it is viewable.
6. In the final response, report the scheme, destination, build status, and run
   status.

The important point is that the agent should not merely run `xcodebuild` and
stop. It should leave the user with a live target Apperture can show.

## Apperture CLI Or Local Bridge

The skill needs a dependable command/API to call. A small helper named
`apperturectl` would make this explicit.

Example shape:

```sh
apperturectl begin-build \
  --project-root /path/to/project \
  --scheme MyApp \
  --destination "platform=iOS Simulator,name=iPhone 16"

apperturectl attach-result-stream \
  --path /tmp/apperture/MyApp-2026-05-06.resultstream.json

apperturectl attach-result-bundle \
  --path /tmp/apperture/MyApp-2026-05-06.xcresult

apperturectl app-running \
  --platform simulator \
  --simulator-udid <udid> \
  --bundle-id com.example.MyApp

apperturectl app-running \
  --platform macos \
  --pid <pid> \
  --bundle-id com.example.MyMacApp \
  --app-path /path/to/MyMacApp.app
```

Implementation options:

- File-based bridge: `apperturectl` writes JSON event files under
  `~/Library/Application Support/Apperture/AgentEvents`, and the Mac app watches
  that directory. This is simple and robust for a first version.
- Local IPC: `apperturectl` talks to the Mac app over localhost TCP, Unix domain
  socket, or XPC. This is cleaner long term but more product work.
- Direct Mac app CLI: `apperturectl` can be bundled inside the app and use
  shared code for event encoding.

Recommended MVP: file-based bridge first, then replace or supplement it with
local IPC once the event schema stabilizes.

## Event Schema

A compact JSON event stream is enough.

```json
{
  "version": 1,
  "kind": "buildStarted",
  "timestamp": "2026-05-06T19:30:00Z",
  "projectRoot": "/Users/me/Developer/MyApp",
  "scheme": "MyApp",
  "destination": "platform=iOS Simulator,name=iPhone 16",
  "resultBundlePath": "/tmp/apperture/MyApp.xcresult",
  "resultStreamPath": "/tmp/apperture/MyApp.resultstream.json"
}
```

Likely event kinds:

- `buildStarted`
- `buildMessage`
- `buildFinished`
- `testStarted`
- `testFinished`
- `simulatorBooted`
- `appInstalled`
- `appLaunched`
- `appRunFailed`

For iOS, `appLaunched` should include simulator UDID and bundle identifier.
For macOS, it should include process ID, bundle identifier, and app path.

## Build Message Sources

### Agent-Driven Builds

This should be the reliable path.

Agents should run `xcodebuild` with:

- `-resultBundlePath <path>`
- `-resultStreamPath <path>` when available
- explicit `-scheme`
- explicit `-destination`
- explicit project or workspace path

The result bundle gives post-build structured data. The result stream can provide
live progress if it is readable while the build is running.

Useful commands:

```sh
xcrun xcresulttool get build-results --path <bundle> --compact
xcrun xcresulttool get log --path <bundle> --type build --compact
xcrun xcresulttool get log --path <bundle> --type action --compact
xcrun xcresulttool get log --path <bundle> --type console --compact
```

### Xcode GUI Builds

This should be treated as best effort.

Xcode writes useful artifacts under DerivedData:

```text
~/Library/Developer/Xcode/DerivedData/*/Logs/Build
~/Library/Developer/Xcode/DerivedData/*/Logs/Launch
~/Library/Developer/Xcode/DerivedData/*/Logs/Console
```

Launch logs commonly appear as `.xcresult` bundles and can be inspected with
`xcresulttool`. Build logs also have `LogStoreManifest.plist`, which exposes
scheme, title, start/stop times, status, warning counts, and error counts.

Full `.xcactivitylog` parsing is less attractive because it is not a stable
public contract. It can be a fallback, but the agent path should use explicit
result bundles and streams instead.

## Launch And View Detection

### Simulator Apps

For iOS apps, the agent should:

1. Select or boot a simulator.
2. Build for that simulator destination.
3. Install the app with `xcrun simctl install`.
4. Launch or relaunch with `xcrun simctl launch`.
5. Notify Apperture with simulator UDID and bundle identifier.

Apperture can then prioritize the Simulator window in its existing window list
and start streaming it.

### macOS Apps

For macOS apps, the agent should launch the built `.app` and notify Apperture
with PID, bundle identifier, and app path.

Apperture can match that PID to windows discovered by `CGWindowList`, then select
and stream the corresponding app window.

The app already tracks process IDs for windows in `WindowDiscoveryService`, so
this is a natural extension of the current model.

## Mac App Responsibilities

Apperture Mac should eventually have an `XcodeIntegrationModel` or similar
service responsible for:

- Watching agent event files or receiving local IPC events.
- Watching DerivedData for best-effort GUI Xcode events.
- Parsing `.xcresult` bundles with `xcresulttool`.
- Tracking the active build/run session.
- Publishing build/run state to the iOS app.
- Matching launched macOS app PIDs to discovered windows.
- Selecting the active Simulator or macOS app window automatically when safe.

The existing remote stream protocol can be extended with a new packet type,
for example `developerActivity`, carrying build and run metadata.

## iOS App Responsibilities

The iOS app should show development context without turning the viewer into a
full IDE.

Useful first UI:

- Current scheme and destination.
- Build state: idle, building, succeeded, failed.
- Warning/error counts.
- Latest important messages.
- Running target: Simulator, macOS app, unavailable.
- A small "show build log" panel or sheet.

The mirrored app should remain primary. Build details should be secondary UI,
probably a drawer or toolbar action.

## Draft Skill: `apperture-xcode-runner`

The distributable skill should live at:

```text
AgentSkills/apperture-xcode-runner/
```

Trigger description:

```yaml
name: apperture-xcode-runner
description: Use when coding agents work on Xcode projects where the app should be built, tested, launched or relaunched in Simulator or on macOS, and made visible through Apperture after the coding task is complete.
```

Core instructions:

1. Inspect the repo for `.xcodeproj`, `.xcworkspace`, `Package.swift`, schemes,
   and platform targets.
2. Prefer an explicit workspace/project, scheme, and destination.
3. Use `xcodebuild` with result bundle and result stream paths under `/tmp` or
   another Apperture-approved temp directory.
4. Notify Apperture before and after build/test/run steps if `apperturectl` is
   available.
5. For iOS apps, boot the simulator, install, and launch the app.
6. For macOS apps, launch the built app and report its PID to Apperture.
7. Final answer must include whether the app is running and viewable.

Bundled scripts could help keep this deterministic:

- `scripts/find_xcode_target.py`
- `scripts/select_simulator.py`
- `scripts/xcode_build_with_results.sh`
- `scripts/launch_simulator_app.sh`
- `scripts/launch_macos_app.sh`

The skill should stay thin. The scripts should handle the fragile command
assembly and parsing.

## MVP Plan

### Phase 1: Agent Notification Contract

- Define JSON event schema.
- Add `apperturectl` or a file-writing helper.
- Add Mac-side watcher for agent event files.
- Display basic build/run state in the Mac host app.

### Phase 2: iOS Developer Activity Packet

- Add shared message models for developer activity.
- Add a new stream packet type.
- Decode and store developer activity in the iOS client.
- Show a compact build/run status panel.

### Phase 3: Simulator Relaunch Workflow

- Implement the skill's simulator workflow.
- Ensure the agent can boot, install, and relaunch the app.
- Notify Apperture with simulator UDID and bundle ID.
- Auto-select or prioritize the Simulator window.

### Phase 4: macOS App Relaunch Workflow

- Implement the skill's macOS launch workflow.
- Notify Apperture with PID and app path.
- Match PID to discovered windows.
- Auto-select the launched app window once visible.

### Phase 5: Xcode GUI Fallback

- Watch DerivedData `Logs/Launch` and `Logs/Build`.
- Parse `LogStoreManifest.plist`.
- Parse `.xcresult` launch bundles with `xcresulttool`.
- Use this only as best-effort enhancement for manual Xcode usage.

## Open Questions

- Should `apperturectl` live inside this repo, inside the packaged Mac app, or as
  a standalone developer tool?
- Should the first bridge be file-based or local IPC?
- Where should temporary result bundles and streams live?
- How much build log detail is useful on iPhone before it becomes noise?
- Should Apperture auto-switch windows on every agent launch, or only when a
  viewer is connected?
- How should conflicting sessions be handled when Xcode GUI and an agent are
  both active?

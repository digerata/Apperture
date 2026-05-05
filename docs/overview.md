# Single-App Remote Mirroring Project Overview

## Working Concept

Build a Mac menubar app and companion iPhone app that lets a developer remotely view and interact with a single running Mac application while away from their desktop.

The core use case is continuing development while working with an agent or remote development workflow. The agent may build and run an app through Xcode, but the developer still needs to see and interact with the resulting app. Traditional screen sharing is poorly suited to this because it exposes the entire desktop, often across multiple large monitors, which is difficult to use from an iPhone.

This product focuses on mirroring the specific app that matters: either the iOS Simulator, which is itself a Mac app, or a macOS app launched by Xcode.

The goal is not generic remote desktop. The goal is a focused, low-latency, high-quality, single-app remote interaction experience optimized for development.

You will find mockups in the mockups directory.

## Problem

When away from the desktop machine, the developer currently has two practical options:

1. Use screen sharing to control the desktop.
2. Wait until returning to the desktop.

Screen sharing is inadequate because:

- It shows too much: full desktop, multiple monitors, unrelated windows.
- Large desktop displays do not translate well to a phone screen.
- The user has to pan, zoom, and hunt for the target app.
- Input is designed around controlling a desktop, not interacting with the running app.
- It lacks development-specific affordances.

Waiting is also inadequate because it breaks the development loop.

## Product Thesis

A single-app mirroring tool can outperform general-purpose remote desktop for this use case by sending fewer pixels, preserving context, optimizing layout for phone screens, and focusing input around the running app rather than the entire Mac.

The product should feel like the selected Mac app is projected onto the iPhone, not like the user is remotely controlling a tiny desktop.

## Primary Use Cases

### 1. iOS Simulator Remote View and Control

The developer runs an iOS app in Simulator on the Mac. The iPhone companion app shows the Simulator output without unnecessary desktop clutter.

Desired behavior:

- Show only the simulated device/app output when possible.
- Avoid showing the simulator device bezel where possible.
- Map iPhone touch input naturally into simulator input.
- Provide development controls such as screenshot, relaunch, rotate, logs, and rebuild hooks.

### 2. Xcode-Launched macOS App Remote View and Control

The developer runs a macOS app from Xcode. The iPhone app mirrors the launched Mac app window.

Desired behavior:

- Include the Mac app chrome/titlebar/window frame.
- Preserve the feel that this is a real Mac app running on the user’s Mac.
- Allow interaction using touch-to-mouse and keyboard input.
- Support one or more related windows where needed.

### 3. Arbitrary Mac App Viewing

Although the primary audience is developers, the system should not foreclose the possibility of mirroring any Mac app.

This is not the initial wedge, but the architecture should avoid assumptions that only Simulator or Xcode-launched apps are valid targets.

## Existing Related Products

### iOS Bridge

Relevant but not directly competitive as a consumer/developer utility.

Observations:

- Feels more like infrastructure for a larger developer platform.
- Supports a low-level, multiplatform viewer/control model.
- Not packaged as an easy solution for an individual developer who simply needs to continue working remotely.
- Its own documentation notes that streaming quality is not yet where they want it.

Takeaway: useful to study conceptually, but not the product experience being targeted.

### Remote Buddy

Relevant as proof that custom high-performance Mac-to-iOS screen interaction is viable.

Observations:

- General-purpose remote Mac interaction product.
- Strong technical claims around low latency, high image quality, and up to 60 fps.
- Not focused on developer workflows or single running app interaction.
- More of a jack-of-all-trades Mac remote control tool.

Takeaway: validates that the experience can be technically good, but the product positioning and UX are different.

### Traditional Remote Desktop / Screen Sharing

Includes macOS Screen Sharing, VNC-style tools, Chrome Remote Desktop, Splashtop, Jump Desktop, AnyDesk, TeamViewer, and similar tools.

Observations:

- Useful fallback tools.
- Optimized around full desktop access.
- Poor fit for large multi-monitor desktops viewed from iPhone.
- Not optimized for a focused Xcode app-preview loop.

Takeaway: the product should avoid becoming another generic remote desktop app.

## UX Principles

### Focus on the Running App

The mirrored app should be the primary object. The user should not have to manage desktop context, find windows, or navigate a multi-monitor layout.

### Do Not Mirror Edge-to-Edge by Default

The mockups intentionally avoid edge-to-edge mirroring. The mirrored app has padding around it to reduce the cramped feeling common in phone-based screen sharing.

This padding also creates room for app controls in areas where the mirrored app cannot usefully exist.

### Preserve Mac Familiarity

The Mac desktop wallpaper can be used in padded areas to give the user a familiar sense that the app is running on their own Mac.

Recommended implementation:

- Capture or retrieve the wallpaper separately.
- Send it once as a static/cached background asset.
- Avoid continuously streaming the desktop background.
- Optionally blur, dim, or crop it for readability.

### Full-Screen iPhone Viewer

The iPhone app should avoid unnecessary native iOS chrome. It should run full-screen and place its own controls in unused or padded regions.

Controls should not compete with the mirrored app. They should live outside the active mirrored viewport whenever possible.

### Use Safe-Area and Aspect-Ratio Gaps Intelligently

The iPhone has physical and system-reserved areas where mirrored app content does not belong. These areas can host controls such as:

- Disconnect/back
- Flashlight-style quick action icon, if relevant
- Settings
- Keyboard toggle
- Command palette
- Orientation toggle
- Zoom mode toggle
- Screenshot/record controls

Avoid placing critical controls too close to system gesture edges.

## Layout Modes

### Simulator Layout

The Simulator target should be treated specially.

Desired behavior:

- Prefer clean simulated device output without the Mac Simulator window chrome.
- Avoid showing the device bezel when possible.
- Fit the simulated screen inside the iPhone viewer with comfortable padding.
- Map touch coordinates directly to simulator coordinates.

This is the closest case to a native-feeling remote app.

### macOS App Layout

For macOS apps, the Mac window chrome should be included. The user is explicitly viewing a Mac app window, not just its content area.

Desired behavior:

- Capture the selected window including titlebar/chrome.
- Preserve the visual identity of the Mac app.
- Fit the window intelligently based on iPhone orientation and app dimensions.
- Allow panning/scrolling when the window does not fit.

### Portrait Modes for Mac Apps

At least three portrait viewing modes should be considered:

#### Fit Width

Useful for narrow Mac apps or utility windows where the full width can be displayed comfortably.

Behavior:

- Scale the app so the full width fits in the iPhone viewport.
- Vertical scrolling/panning may be needed.

#### Fit Height

Useful when the full height is more important and horizontal panning is acceptable.

Behavior:

- Scale the app so the full height fits in the iPhone viewport.
- Horizontal scrolling/panning may be needed.

#### Readable Zoom

Useful for wider desktop apps, child-window scenarios, and apps with dense controls or text.

Behavior:

- Scale the app to a readable size rather than forcing the whole window to fit.
- Allow one-axis or two-axis panning depending on the target layout.
- Potentially support focus regions or quick jump points.

### Landscape Mode for Mac Apps

Landscape is likely the preferred orientation for many Mac apps.

Behavior:

- Fit the app to one axis where possible.
- Prefer one-directional scrolling/panning.
- Use side safe areas for controls.
- Preserve a spacious feel while keeping the app readable.

## Multi-Window Considerations

macOS apps may create child windows, panels, sheets, dialogs, popovers, inspectors, or auxiliary windows.

The app should eventually support capturing more than one related window.

Potential approaches:

### Single Primary Window Mode

The initial simplest mode.

- User selects one window.
- Only that window is streamed.
- Dialogs or child windows may be missed unless they are part of the same captured surface.

### App Window Group Mode

Capture multiple windows belonging to the same app.

- Useful for dialogs, utility panels, inspectors, and child windows.
- Requires composition on the Mac host or iPhone client.
- Needs window z-order and coordinate preservation.

### Manual Add Window Mode

Allow the user to add secondary windows to the mirrored session.

- Useful when automatic grouping is unreliable.
- Keeps v1 simpler than fully automatic multi-window capture.

### Readable Zoom for Multi-Window

When multiple windows are captured, readable zoom becomes more important than strict fit-to-axis behavior.

The user may need to pan around a composed workspace containing the app’s main window plus child windows.

## Technical Architecture

### High-Level Architecture

```text
Mac menubar host
  ├─ discover running apps and windows
  ├─ let user select target app/window/session
  ├─ capture selected window, app, or Simulator output
  ├─ encode video using low-latency hardware encoding
  ├─ stream video to iPhone
  ├─ receive input/control events from iPhone
  ├─ inject mouse/keyboard input or call semantic controls
  └─ provide optional Xcode/agent/developer commands

IPhone client
  ├─ connect to Mac host over private network/Tailscale
  ├─ receive and decode low-latency video
  ├─ render mirrored app inside optimized viewport
  ├─ provide touch, keyboard, and gesture input
  ├─ expose command overlay and session controls
  └─ support orientation-specific layout modes
```

## Capture Strategy

### For iOS Simulator

Preferred target: clean simulator output without the Mac Simulator window chrome or device bezel.

Possible approaches:

1. Use `xcrun simctl io booted screenshot` for early proof-of-concept still capture.
2. Use `xcrun simctl io booted recordVideo` as proof that clean simulator video output exists.
3. Investigate whether there is a supported low-latency live framebuffer path.
4. If needed, fall back to ScreenCaptureKit capturing the Simulator window and cropping to the device content area.

Important distinction:

- Simulator should be special-cased.
- It should not necessarily be treated as a generic Mac window.
- Clean device output is more valuable than showing Simulator.app chrome.

### For macOS Apps

Use ScreenCaptureKit to capture the selected app window.

For macOS app targets, capture should include the window chrome/titlebar. That is part of the app’s identity and expected behavior.

Capture options to explore:

- Single selected window
- Multiple windows from one app
- Window group composition
- Whole app capture if possible
- Fallback display-region capture if required

## Video Encoding

Use hardware-accelerated encoding via VideoToolbox.

Initial recommendation:

```text
Codec: H.264
FPS: 30 default, 60 optional
Encoding: low-latency / real-time
B-frames: disabled
Keyframe interval: short, around 1–2 seconds
Resolution: adaptive to target viewport and network quality
Bitrate: adaptive
```

Potential future option:

```text
Codec: HEVC
Use when both devices support it and network bandwidth is constrained.
```

Prioritize:

- Readable text
- Consistent latency
- Fast input feedback
- No large stalls
- Adaptive quality under poor network conditions

## Transport

### MVP Transport: WebRTC

WebRTC is the recommended first transport because it provides:

- Low-latency video transport
- Jitter buffering
- Congestion control
- Hardware decode support
- Data channels for input/control
- NAT traversal if needed

Tailscale can simplify peer discovery and connectivity by putting the Mac and iPhone on the same private network.

### Future Transport: QUIC / Custom Protocol

A custom QUIC-based transport may eventually be useful for tighter control over latency and quality.

However, custom transport would require implementing or tuning:

- Packetization
- Congestion behavior
- Jitter management
- Recovery strategy
- Keyframe requests
- Input side channel
- Reconnection behavior

This should not be v1 unless WebRTC proves inadequate.

## Input Strategy

### Coordinate Mapping

Every interaction must map accurately from the iPhone viewport back to the Mac target.

Mapping path:

```text
iPhone screen point
→ viewer safe-area point
→ padded mirrored viewport point
→ scaled video coordinate
→ captured window/session coordinate
→ Mac screen/window coordinate
```

This needs to account for:

- Current zoom mode
- Current pan offset
- Retina backing scale
- Window movement or resizing
- Multiple captured windows
- Simulator device scale
- Orientation changes

### Simulator Input

Simulator can feel more native because iPhone touch maps well to the simulated device.

Potential input events:

- Tap
- Drag/swipe
- Long press
- Multi-touch gestures if feasible
- Text entry
- Hardware/software keyboard events
- Rotate device
- Shake
- Home/lock-style actions if useful

### macOS App Input

Mac apps require touch-to-mouse translation.

Potential input events:

- Tap as click
- Long press as right-click or context menu
- Drag as mouse drag
- Two-finger pan as scroll
- Pinch for viewer zoom rather than app zoom by default
- Keyboard entry via iPhone keyboard
- Modifier keys via command overlay
- Common shortcuts via toolbar buttons

Semantic commands should be used where possible instead of only synthetic input.

Examples:

- Relaunch app
- Rebuild/run
- Take screenshot
- Show logs
- Reset simulator
- Toggle orientation
- Send keyboard shortcut

## Network and Latency Goals

The product should aim to match or beat the perceived quality of macOS Screen Sharing for the single-window use case.

A rough latency budget:

```text
Capture:        5–16 ms
Encode:         5–20 ms
Network:       20–100+ ms
Jitter buffer: 10–50 ms
Decode/render:  5–16 ms
Input return:  20–100+ ms
```

The system should adapt to connection quality.

Example modes:

```text
Excellent connection:
  60 fps, high bitrate, high sharpness

Good connection:
  30 fps, high sharpness, moderate bitrate

Weak connection:
  20–30 fps, lower resolution, prioritize input latency

Poor connection:
  reduce frame rate aggressively, preserve interactivity
```

Avoid TCP-style head-of-line blocking for real-time video when possible.

## Discovery and Pairing

Because the user already uses Tailscale, v1 can assume both devices are reachable on a private network.

Possible pairing flow:

1. Mac menubar app starts local listener.
2. iPhone app discovers Mac hosts on Tailscale/local network or accepts manual host entry.
3. User selects Mac.
4. Mac confirms connection request.
5. iPhone selects available target window/app/session.

Security requirements:

- Explicit pairing approval.
- Local/private-network-first model.
- No cloud relay required for v1.
- Clear indication when mirroring is active.
- Ability to immediately stop streaming from either device.

## Mac Host App

Initial responsibilities:

- Menubar presence.
- Show current connection status.
- List available windows/apps.
- Let the user select a target.
- Start/stop streaming.
- Manage capture permissions.
- Manage accessibility/input permissions.
- Serve video stream and receive control events.
- Provide wallpaper/background asset to iPhone client.
- Optionally expose Xcode/development commands.

Future responsibilities:

- Detect Xcode-launched app automatically.
- Detect Simulator instances automatically.
- Group related windows.
- Provide app-specific presets.
- Integrate with agents or local automation scripts.

## iPhone Client App

Initial responsibilities:

- Full-screen viewer.
- Connection selection and pairing.
- Render mirrored app in padded viewport.
- Use Mac wallpaper/static background in padding.
- Provide controls in unused/safe areas.
- Support portrait and landscape layout modes.
- Send touch, keyboard, and command input.
- Provide zoom/pan controls.

Important viewer controls:

- Disconnect/back
- Settings
- Keyboard
- Zoom mode
- Orientation lock/toggle
- Screenshot
- Command palette
- Pointer/mouse mode if needed

## Permissions

The product will require permissions that users are likely willing to grant because the value is clear.

Expected macOS permissions:

- Screen Recording / Screen & System Audio Recording equivalent
- Accessibility for input control
- Input Monitoring if keyboard event handling requires it
- Local network permission on iOS
- Potential file access or API access for wallpaper retrieval

The onboarding should explain the permissions in terms of the desired user outcome, not generic technical language.

## Important Technical Risks

### 1. Clean Live Simulator Capture

Still screenshots and recorded video are easy to prove with `simctl`, but low-latency live clean framebuffer capture may not have a straightforward public API.

Fallback: capture Simulator.app window with ScreenCaptureKit and crop to device content.

### 2. Multi-Window Capture

Capturing one window is simpler than capturing an app session with multiple related windows.

Risk areas:

- Dialogs
- Sheets
- Popovers
- Utility panels
- Window z-order
- Coordinate mapping across multiple windows

Potential v1 approach: single-window capture plus manual add-window support.

### 3. Input Accuracy

Coordinate mapping must remain correct through:

- Window movement
- Resizing
- Orientation change
- Zoom mode changes
- Retina scale differences
- Stream resolution changes

Keyboard input also needs two distinct paths:

- Physical key injection for normal keys and shortcuts.
- Exact text insertion for arbitrary Unicode, including emoji, without using or mutating the Mac pasteboard.

### 4. Network Variability

The system may work very well on direct Tailscale paths and less well when relayed.

The UI should show connection quality and adapt rather than silently degrading.

### 5. Text Readability

For development work, text clarity is more important than video smoothness.

The encoder and scaling pipeline should be tuned around sharp UI rendering, not just motion.

## MVP Scope

### MVP 1: Single Mac Window Mirror

Goal: prove that a single selected Mac app window can be mirrored and controlled from iPhone with better usability than full desktop sharing.

Features:

- Mac menubar host.
- iPhone full-screen client.
- Manual target window selection.
- ScreenCaptureKit single-window capture.
- H.264 hardware encoding.
- WebRTC streaming.
- Touch-to-mouse input.
- Keyboard input.
- Portrait/landscape rendering.
- Padding and background treatment.
- Basic zoom modes: fit width, fit height, readable zoom.

### MVP 2: Simulator-Optimized Mode

Goal: make the iOS Simulator experience feel first-class.

Features:

- Detect Simulator windows/devices.
- Prefer clean simulator output without device bezel if feasible.
- Fall back to cropped Simulator window capture if needed.
- Map touches to simulator coordinates.
- Add simulator-specific commands:
  - Rotate
  - Screenshot
  - Relaunch
  - Reset
  - Paste text
  - Shake

### MVP 3: Development Workflow Layer

Goal: make this meaningfully better than screen sharing for agent-assisted development.

Features:

- Rebuild/run command hook.
- Show latest build status.
- Show app logs or console tail.
- Trigger screenshot capture and share with agent.
- Command palette for common developer actions.
- Optional integration with local scripts.

### MVP 4: Multi-Window Support

Goal: handle real macOS app behavior.

Features:

- Add secondary windows manually.
- Compose related windows into a session.
- Preserve z-order.
- Support readable zoom and panning across composed window space.
- Handle dialogs and sheets more gracefully.

## Open Questions

1. Can clean iOS Simulator output be captured live with acceptable latency using only supported public APIs?
2. How reliable is ScreenCaptureKit single-window capture for hidden, occluded, minimized, or offscreen windows?
3. What is the best default zoom mode for portrait Mac app viewing?
4. Should the iPhone client default to landscape for Mac apps and portrait for Simulator?
5. How should multiple windows be represented visually on the iPhone?
6. Should controls be persistent, auto-hiding, or revealed through gestures?
7. How much Xcode/agent integration belongs in the product versus being delegated to user scripts?
8. Should Tailscale be assumed, recommended, or fully optional?
9. Should the product support iPad from the beginning?
10. What is the minimum acceptable latency target for the app to feel useful?

## Suggested Prototype Plan

### Prototype A: Window Capture and Local Display

- Build a Mac app that lists windows.
- Capture one selected window using ScreenCaptureKit.
- Render locally in a test viewer.
- Confirm quality, chrome inclusion, resize behavior, and occlusion behavior.

### Prototype B: Mac-to-iPhone Video Stream

- Add VideoToolbox encoding.
- Stream to iPhone over WebRTC.
- Render inside padded viewport.
- Add static wallpaper background.
- Test on Tailscale and local Wi-Fi.
- Optimize streaming performance until interaction feels fluid, not merely usable.

### Prototype C: Input Round Trip

- Send touch events from iPhone to Mac.
- Map touch coordinates to captured window coordinates.
- Inject mouse clicks/drags.
- Add keyboard entry.
- Add exact Unicode text entry without relying on the Mac pasteboard.
- Measure perceived latency.

### Prototype D: Simulator Specialization

- Detect Simulator.
- Test clean screenshot/video capture paths.
- Attempt live clean output path.
- If unavailable, implement cropped ScreenCaptureKit fallback.
- Add simulator-specific command controls.

### Prototype E: Layout and Zoom Modes

- Implement fit width.
- Implement fit height.
- Implement readable zoom.
- Implement orientation-specific defaults.
- Test with narrow apps, wide apps, and child-window scenarios.

## Positioning

Potential positioning:

> A focused remote app viewer for developers who need to keep working from their iPhone while their Mac builds and runs apps.

Alternative:

> Remote control for the app you are building, not the whole desktop.

Core differentiation:

- Single-app focus.
- Better phone UX than full desktop screen sharing.
- Simulator-aware.
- Mac app chrome preserved where appropriate.
- Developer workflow controls.
- Designed for agent-assisted development.
- Private-network/Tailscale-friendly.

## Non-Goals for Early Versions

- Full replacement for remote desktop.
- Full multi-monitor control.
- Perfect arbitrary Mac app touch adaptation.
- Cloud relay infrastructure.
- Team/device fleet management.
- Cross-platform viewers beyond iPhone/iPad.
- General automation platform.

## Summary

The project is technically plausible and product-differentiated.

The strongest wedge is not generic screen sharing, but focused single-app remote development. The first-class targets are iOS Simulator and Xcode-launched macOS apps. The UX should preserve familiar Mac context without exposing the entire desktop, use padded full-screen presentation on iPhone, and provide layout modes that make desktop apps usable on a small screen.

The likely v1 architecture is ScreenCaptureKit plus VideoToolbox plus WebRTC, with Tailscale simplifying connectivity. Simulator should receive special handling to avoid unnecessary bezels and chrome when possible. macOS apps should retain their window chrome. Multi-window support should be planned but staged after single-window capture and input are proven.

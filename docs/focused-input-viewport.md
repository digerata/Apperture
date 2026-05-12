# Focused Input Viewport Adjustment

This document captures a future implementation idea for improving iOS keyboard entry while mirroring a Mac app.

The goal is to let the Mac host detect which input field is focused in the mirrored app, send that focused rect to the iOS client, and allow the client to adjust the mirrored viewport so the content being typed remains visible above the iOS keyboard and accessory toolbar.

## Motivation

When the iOS software keyboard is visible, the client currently avoids the keyboard at the viewport level. That is useful, but it does not know what the user is typing into. If the focused field is near the bottom of the mirrored Mac window, the keyboard can still make the interaction feel cramped or blind.

The better behavior is closer to native iOS:

- The focused input remains visible while typing.
- The viewport moves only as much as needed.
- The adjustment follows the actual focused field or caret, not just a generic keyboard inset.
- The user can still pan/zoom manually if the automatic choice is not right.

## Feasibility

This should be feasible on the Mac host using Accessibility.

The host already uses Accessibility APIs in `RemoteInputInjectionService` to bring the selected app forward, match an AX window to the selected captured window, and read an AX element frame with `kAXPositionAttribute` and `kAXSizeAttribute`.

Relevant implementation points already exist in:

- `Sources/Mac/RemoteInputInjectionService.swift`
- `Sources/Mac/HostModel.swift`
- `Sources/Mac/RemoteFrameStreamServer.swift`
- `Sources/iOS/RemoteFrameStreamClient.swift`
- `Sources/iOS/iPhoneViewerView.swift`
- `Sources/Shared/RemoteFrameStreamConfiguration.swift`

Apple APIs likely involved:

- `AXObserverCreate`
- `AXObserverAddNotification`
- `kAXFocusedUIElementChangedNotification`
- `kAXFocusedUIElementAttribute`
- `kAXPositionAttribute`
- `kAXSizeAttribute`
- `kAXRoleAttribute`
- `kAXSubroleAttribute`
- `kAXSelectedTextRangeAttribute`
- `kAXBoundsForRangeParameterizedAttribute`

Reference links:

- https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate
- https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification
- https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue
- https://developer.apple.com/documentation/applicationservices/kaxpositionattribute
- https://developer.apple.com/documentation/applicationservices/kaxsizeattribute
- https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute

## Proposed Host-Side Shape

Add a host-side focused element monitor, probably something like `FocusedElementMonitor`.

Responsibilities:

1. Track the currently selected `MirrorWindow`.
2. Create an app AX element with `AXUIElementCreateApplication(selectedWindow.processID)`.
3. Install an `AXObserver` for `kAXFocusedUIElementChangedNotification`.
4. On notification, read `kAXFocusedUIElementAttribute`.
5. Validate that the focused element belongs to the selected mirrored window.
6. Read the focused element's role/subrole.
7. If it is text-input-like, read its screen-space rect.
8. Try to read a caret or selected-text bounds rect when available.
9. Normalize the rect into the current capture coordinate space.
10. Publish a host-to-client focus context packet.

The monitor should be restarted when:

- The selected window changes.
- The stream starts or restarts.
- The target process exits.
- Accessibility permission changes.

It should stop when:

- No window is selected.
- Streaming stops.
- The host loses Accessibility permission.

## Observer Plus Polling

Do not rely only on AX notifications.

Some apps are inconsistent about posting focus notifications. The host should also opportunistically poll the focused element after local events that can change focus:

- Pointer down
- Text input
- Key press
- Key chord
- Window selection
- Stream restart

Polling does not need to be aggressive. A short debounce after input, plus notification-driven updates, should be enough.

## Determining Whether the Element Belongs to the Mirrored Window

The monitor should avoid sending focus rects from another window in the same process.

Possible checks:

- Read `kAXTopLevelUIElementAttribute` from the focused element and compare its frame to the selected `MirrorWindow.frame`.
- Compare the focused element frame against the selected capture frame.
- Reuse the existing AX window matching logic from `RemoteInputInjectionService`.
- Treat focus as invalid if the focused element is outside the selected capture frame by more than a small tolerance.

This matters for apps with multiple windows, sheets, inspectors, floating panels, and popovers.

## Rect Strategy

Prefer the most precise useful rect:

1. Caret rect, if available.
2. Selected text bounds, if available.
3. Focused text element rect.
4. No rect.

The caret rect is the best target for large multiline editors. The focused element rect is good enough for normal text fields, search fields, and small controls.

The message can include both caret and element rects so the client can choose:

```swift
struct RemoteFocusContextMessage: Codable, Equatable {
    var windowID: UInt32
    var generation: UInt64
    var isTextInput: Bool
    var role: String?
    var subrole: String?
    var focusedRect: NormalizedRect?
    var caretRect: NormalizedRect?
}

struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
```

Coordinates should be normalized relative to the active capture screen frame, not absolute screen pixels. That keeps the client independent from Mac display scale and current capture size.

## Protocol Addition

Add a new host-to-client packet type in `RemoteFrameStreamConfiguration.PacketType`, for example:

```swift
case focusContext = 13
```

The packet body should be JSON encoded.

The server can keep the last focus context and replay it to newly authenticated clients if it is still valid for the current selected window/stream generation.

The client should clear focus context when:

- It receives a stream reset.
- The selected window changes.
- The host sends `isTextInput: false`.
- The keyboard hides, if the client does not need the context anymore.

## iOS Client Behavior

The first client behavior should be conservative:

1. Store the latest focus context on `RemoteFrameStreamClient`.
2. When the keyboard is visible, map the normalized focus/caret rect into the rendered mirror view.
3. If the rect intersects the keyboard/accessory-obscured area, shift the mirrored app up just enough to reveal it with padding.
4. Animate with the same timing curve as the keyboard.
5. Reset when the keyboard hides.

Recommended initial policy:

- Prefer `caretRect` over `focusedRect`.
- Add 16-24 points of padding around the target rect.
- Do not zoom automatically at first.
- Do not fight user pan/zoom gestures while the user is actively manipulating the viewport.
- Debounce incoming focus updates so typing does not cause visible jitter.

Later policies could be smarter:

- Center the caret in the available area for large editors.
- Temporarily zoom to fit narrow inputs in portrait.
- Preserve manual user viewport adjustments until focus changes.
- Add a setting to disable automatic keyboard viewport adjustment.

## Known Caveats

Accessibility quality varies by app.

Likely good:

- Native AppKit apps
- Catalyst apps
- Standard text fields
- Standard search fields
- Standard text views

Likely mixed:

- Electron apps
- Browser-hosted web apps
- Code editors
- Terminal apps
- Custom canvas-rendered UIs
- Apps with custom accessibility implementations

Failure modes to expect:

- Focused element is a large web area/editor container.
- Position or size is unavailable.
- The app reports focus notifications inconsistently.
- The focused element belongs to another window in the same process.
- Secure fields expose frame but not text details.
- Caret bounds are unavailable even though focused element bounds are available.

The feature should degrade gracefully. If there is no reliable rect, the client should keep the current keyboard avoidance behavior.

## Implementation Plan

1. Add shared focus context models.
2. Add a `focusContext` host-to-client packet type.
3. Add packet publishing and decoding support in `RemoteFrameStreamServer` and `RemoteFrameStreamClient`.
4. Add `FocusedElementMonitor` on macOS.
5. Wire the monitor into `HostModel` selected-window and stream lifecycle.
6. Publish focus context on AX notification and after relevant input events.
7. Add iOS viewport adjustment using the latest focus context.
8. Test against native text fields, multiline text views, Safari/Chrome web inputs, Terminal, and common editor apps.

## Open Questions

- Should focus context be sent only while the iOS keyboard is visible, or always while streaming?
- Should the client request focus context explicitly when the keyboard appears?
- Should host-side monitoring run while no client is connected?
- Should focus context be tied to stream generation, selected window ID, or both?
- How much manual pan/zoom state should automatic adjustment preserve?
- Should caret tracking update while typing, or only when focus changes and selection changes?

## Recommendation

Prototype this as a small host-to-client data path first. The first version should only send a normalized focused element rect and make the iOS client reveal it above the keyboard. Once that is stable, add caret rect support and smarter viewport policies.

This gives us useful behavior quickly while leaving room for a more native-feeling keyboard interaction model later.

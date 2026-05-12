# Apperture Host/Client Protocol

This document describes the current protocol between the macOS host app and the iOS client app. The implementation lives primarily in:

- `Sources/Mac/RemoteFrameStreamServer.swift`
- `Sources/iOS/RemoteFrameStreamClient.swift`
- `Sources/Shared/RemoteFrameStreamConfiguration.swift`
- `Sources/Shared/PairingModels.swift`
- `Sources/Shared/RemoteControlMessage.swift`
- `Sources/Shared/RemoteVideoMessages.swift`
- `Sources/Shared/RemoteWindowListMessage.swift`

## Roles

The Mac is the host. It discovers windows, captures the selected window, encodes frames, publishes state, and injects approved input events into the selected app.

The iPhone or iPad is the client. It discovers or directly connects to the Mac, authenticates using a saved pairing, receives host state and video packets, and sends control messages for window selection, stream startup, pointer, scroll, and keyboard input.

The transport is a single TCP connection per client. It carries both the host-to-client stream and client-to-host control messages.

## Discovery and Connection

The host listens with `NWListener` on TCP port `58224` and advertises Bonjour service type `_apperture._tcp` in the `local.` domain. The listener uses TCP with `noDelay` enabled, no TLS, local endpoint reuse, and peer-to-peer support.

The iOS client builds connection candidates from:

- Bonjour results for `_apperture._tcp`.
- Saved paired-host endpoint hints.
- Saved manual endpoints such as `hostname:58224`, a Tailscale IP, or an IPv6 bracket form.
- A debug-only simulator loopback candidate on `127.0.0.1:58224`.

Client connections use TCP with `noDelay`, keepalive enabled, and peer-to-peer support. The client also probes candidates with short-lived TCP connections to mark hosts as reachable before automatic connection.

## Framing

Every message on the TCP stream begins with a 4-byte unsigned big-endian length.

Client-to-host payload:

```text
uint32_be jsonLength
json bytes
```

The client JSON payload is normally a `RemoteClientEnvelope`, encoded with `JSONEncoder.apperture`, which means ISO-8601 dates. The host also accepts a legacy bare `RemoteControlMessage` JSON payload after authentication.

Host-to-client payload:

```text
uint32_be packetLength
uint8 packetType
packet bytes
```

`packetLength` includes the `packetType` byte. The iOS client rejects host packets with length `0` or length greater than or equal to `24_000_000` bytes. The host rejects client control payloads with length `0` or length greater than `1_048_576` bytes.

Most host packet bodies are JSON encoded with default `JSONEncoder`. The exceptions are pairing/auth packets, which use ISO-8601 `JSONEncoder.apperture`, and binary image/video packets.

## Packet Types

| ID | Name | Direction | Body |
| --- | --- | --- | --- |
| `0` | `frame` | Host to client | Legacy JPEG or PNG image bytes. Kept for compatibility; H.264 packets are the normal path. |
| `1` | `wallpaper` | Host to client | JPEG image bytes for the selected window's desktop wallpaper/background context. |
| `2` | `windowList` | Host to client | JSON `RemoteWindowListMessage`. |
| `3` | `videoFormat` | Host to client | JSON `RemoteVideoFormatMessage` with H.264 width, height, SPS, and PPS. |
| `4` | `videoFrame` | Host to client | Binary `RemoteVideoFrameMessage` payload. |
| `5` | `videoMask` | Host to client | PNG alpha-mask bytes, or an empty body to clear the mask. |
| `6` | `streamDiagnostics` | Host to client | JSON `RemoteStreamDiagnosticsMessage`. |
| `7` | `developerActivity` | Host to client | JSON `DeveloperActivityEvent`. |
| `8` | `streamReset` | Host to client | No body. Signals that the current stream generation is invalid. |
| `9` | `hostInfo` | Host to client | JSON `RemoteHostInfoMessage`. |
| `10` | `appIcon` | Host to client | JSON `RemoteAppIconMessage`, including PNG bytes as JSON `Data`. |
| `11` | `pairingResponse` | Host to client | ISO-8601 JSON `PairingResponse`. |
| `12` | `authStatus` | Host to client | ISO-8601 JSON `PairingAuthStatus`. |
| `13` | `clipboard` | Host to client | JSON `RemoteClipboardMessage` containing plain text copied from the mirrored Mac app. |

If a host payload begins with an unknown byte, the iOS client treats the whole payload as a legacy image frame unless it is currently waiting for a stream reset after a window selection.

## Client Envelopes

Client messages use `RemoteClientEnvelope`:

```json
{
  "kind": "authRequest",
  "pairingRequest": null,
  "authRequest": { "...": "..." },
  "control": null,
  "clipboard": null
}
```

Valid `kind` values are:

- `pairingRequest`: carries a `PairingRequest`.
- `authRequest`: carries a `PairingAuthRequest`.
- `control`: carries a `RemoteControlMessage`.
- `clipboard`: carries a `RemoteClipboardMessage` from the iOS pasteboard to the Mac host.

The host closes the connection for malformed envelopes, unauthenticated control or clipboard messages, invalid legacy control payloads, or failed authentication.

## Pairing

Pairing starts on the Mac. The host creates a `PairingOffer` with protocol version `1`, a random 8-byte base64url offer ID, a random 32-byte base64url shared secret, endpoint hints, port `58224`, creation time, and an expiration time 120 seconds later.

The current QR payload is compact:

```text
apperture://p?o=<offerID>&s=<sharedSecret>&e=<firstEndpointHint>&x=<expiresAtUnixSeconds>
```

The decoder still supports older/alternate QR forms:

- `apperture://p?d=<base64url compact JSON>`
- `apperture://pair?payload=<base64url PairingOffer JSON>`

After scanning, the client sends:

```json
{
  "kind": "pairingRequest",
  "pairingRequest": {
    "offerID": "...",
    "phoneIdentity": {
      "id": "...",
      "displayName": "...",
      "kind": "iPhone",
      "symbolName": "iphone"
    },
    "requestedAt": "2026-05-12T...",
    "proof": "..."
  }
}
```

The proof is `HMAC-SHA256(secret, "pairing-request|<offerID>|<phoneIdentity.id>")`, base64url encoded. The Mac validates the offer ID, expiration, and proof, then asks the Mac owner to approve the device. When approved, the Mac stores the phone as a `PairedDevice` and sends a `pairingResponse` packet. The response includes the paired device record and a `PairingHostProfile` derived from the offer.

The shared secret is the QR secret. Both sides store pairing identities and paired-device records in the local Keychain under service `com.landmk1.apperture.pairing`; it is marked `AfterFirstUnlockThisDeviceOnly`, so it is local to the device.

## Authentication

Normal streaming connections must authenticate before receiving host state or sending control messages.

The client sends:

```json
{
  "kind": "authRequest",
  "authRequest": {
    "pairID": "<pairedDevice.id>",
    "peerDeviceID": "<localClientIdentity.id>",
    "nonce": "<random base64url>",
    "proof": "<base64url hmac>"
  }
}
```

The proof is `HMAC-SHA256(sharedSecret, "pairing-auth|<pairID>|<peerDeviceID>|<nonce>")`, base64url encoded.

The host accepts only if:

- The remote endpoint is private, local, loopback, or Tailscale-style `100.64.0.0/10`.
- A non-revoked paired device matches `pairID` and `peerDeviceID`.
- The HMAC proof matches the stored shared secret.

On success the host marks the connection ready, starts a local audit session, sends `authStatus accepted`, sends `hostInfo`, and replays current stream state where available. On failure it sends `authStatus rejected` and closes the connection.

This protocol authenticates the peer but does not encrypt the TCP stream. The design relies on private-network access plus HMAC pairing/authentication, not TLS confidentiality.

## Initial State After Authentication

After successful authentication, the host may send these packets immediately:

1. `authStatus accepted`
2. `hostInfo`
3. `wallpaper`, if already available
4. `videoFormat`, if already available
5. `videoMask`, if already available
6. `clipboard`, if the host has a cached remote clipboard value
7. The last encoded frame, but only if it is a key frame

The host intentionally does not replay a cached window list during authorization. `HostModel` refreshes windows after authentication and publishes a fresh list.

If the last encoded frame is not a key frame, the connection is marked as needing a key frame and the encoder is asked to produce one.

## Control Messages

`RemoteControlMessage` is sent inside a `RemoteClientEnvelope.control`.

Common fields:

- `kind`: command name.
- `normalizedX`, `normalizedY`: clamped `0...1` coordinates within the current target frame.
- `sequenceNumber`: monotonically increasing client-side number. It is currently used for ordering/debugging semantics, not explicit acknowledgement.
- Optional fields depending on command: `text`, `key`, `modifiers`, `windowID`, `scrollDeltaX`, `scrollDeltaY`, `scrollPhase`.

Commands:

| Kind | Required fields | Host behavior |
| --- | --- | --- |
| `requestWindowList` | none beyond common fields | Refreshes or republishes the streamable window list. Refreshes are coalesced to one second. |
| `selectWindow` | `windowID` | Refreshes windows, selects the requested window if present, publishes a new window list, records the selection in the active audit session, and starts live view. |
| `startStream` | none beyond common fields | Refreshes windows, publishes the list, and starts live view for the selected window if not already running. |
| `requestKeyFrame` | none beyond common fields | Marks this connection as needing a key frame and requests a key frame from the encoder. It is handled inside the frame server and not forwarded to `HostModel`. |
| `pointerDown` | normalized coordinates | Focuses/raises the selected app if needed and posts a left mouse down. |
| `pointerMove` | normalized coordinates | Posts mouse moved or left mouse dragged, depending on pointer-down state. |
| `pointerUp` | normalized coordinates | Posts left mouse up and clears pointer-down state. |
| `scroll` | normalized coordinates, deltas, optional phase | Focuses the selected app if needed, moves the cursor, clamps deltas to `-320...320`, and posts a continuous pixel scroll event. |
| `textInput` | `text`, optional `modifiers` | Focuses the selected app and posts text as keyboard events. Newlines become Return; tabs become Tab. |
| `keyPress` | `key`, optional `modifiers` | Focuses the selected app and posts one supported special key. |

Supported `key` values are `deleteBackward`, `returnKey`, `tab`, and `escape`.

Supported `modifiers` are `shift`, `control`, `option`, and `command`.

## Clipboard Messages

`RemoteClipboardMessage` is used for text-only clipboard sharing between the Mac host and iOS client.

Fields:

- `kind`: currently always `plainText`.
- `text`: the clipboard string.
- `sequenceNumber`: monotonically increasing sender-side number for ordering/debugging semantics.

The iOS client sends `RemoteClientEnvelope.clipboard` immediately before sending a Paste command from the keyboard accessory toolbar. The Mac host writes that text into `NSPasteboard.general`, then receives the following Cmd-V key chord normally.

The Mac host publishes a `clipboard` packet after remote Cmd-C or Cmd-X changes `NSPasteboard.general`. The iOS client writes the received text into `UIPasteboard.general`, allowing it to be pasted into other iOS apps.

Only plain text is synchronized. Images, files, attributed strings, and other pasteboard item types are intentionally ignored.

Supported `scrollPhase` values are `began`, `changed`, `ended`, `cancelled`, `momentumBegan`, `momentumChanged`, and `momentumEnded`. The current Mac event posting path does not encode phase into the emitted `CGEvent`; it uses the deltas to post continuous scroll events.

## Window List and Icons

`RemoteWindowListMessage` contains `[RemoteWindowSummary]`. Each summary includes:

- `id`: the `CGWindowID` used by `selectWindow`.
- `title`: user-visible window title, falling back to `Main Window`.
- `subtitle`: currently the window size.
- `isSelected`: whether this is the host's selected window.
- `isSimulator`: whether the host thinks this is a Simulator window.
- `appName`, `appBundleIdentifier`.
- `appIconPNGData`: supported by the model, but the current host list packet sends `nil` here and sends icons separately.

The host sends `appIcon` packets keyed by `appGroupID`, which is `appBundleIdentifier` if available, otherwise the lowercased display app name. The client caches icon PNG data in `UserDefaults` and patches window summaries as icons arrive.

## Video Stream

The normal video path is H.264:

1. The host captures the selected window with `LiveWindowCaptureService`.
2. The host encodes frames with VideoToolbox using H.264 Main profile, real-time mode, no frame reordering, target 30 fps, and adaptive bitrate/quality.
3. The host sends `videoFormat` whenever the H.264 format changes.
4. The host sends `videoFrame` packets for encoded samples.
5. The client configures a `CMVideoFormatDescription` from SPS/PPS and decodes frames into sample buffers.

`RemoteVideoFormatMessage` JSON fields:

- `width`
- `height`
- `sps`: JSON `Data`
- `pps`: JSON `Data`

`videoFrame` uses a compact binary body after the packet type:

```text
uint8 isKeyFrame          // 1 for key frame, 0 otherwise
uint64_be presentationTimeDoubleBits
uint64_be durationDoubleBits
uint32_be h264ByteCount
byte[h264ByteCount] h264SampleData
```

The H.264 sample data is the sample bytes from the VideoToolbox block buffer. The decoder expects 4-byte NAL unit lengths, matching the format description created with `nalUnitHeaderLength: 4`.

The binary decoder has a JSON fallback for older `RemoteVideoFrameMessage` bodies, but the server currently emits the binary form.

## Alpha Masks and Wallpaper

When the selected captured content has transparency, the host may send a `videoMask` packet. The mask is a PNG generated from the alpha channel. The client uses it as an overlay/mask for rendering the remote content.

An empty `videoMask` body clears the mask.

The host may also send a `wallpaper` JPEG for the screen containing the selected window. This lets the client present transparent or shaped windows against a reasonable desktop background.

## Stream Reset and Window Switching

The host sends `streamReset` when live view is reset or the selected stream changes. The client increments its decode generation, clears the current frame, resets the decoder, and waits for fresh format/frame data.

During a window-selection transition, the client ignores video-related packets until it receives `streamReset`. Packets still allowed during that waiting state are:

- `wallpaper`
- `windowList`
- `appIcon`
- `streamDiagnostics`
- `developerActivity`
- `streamReset`
- `hostInfo`
- `pairingResponse`
- `authStatus`

The host tracks connections that need a key frame. If a connection misses frames due to backpressure or joins without a cached key frame, non-key frames are dropped for that connection until a key frame is available.

## Backpressure and Adaptation

The host keeps at most one pending frame per client. If a new frame arrives while a previous frame is still pending for a client, the host drops the older pending work, marks the connection as needing a key frame, and requests a key frame no more than once per second.

Once per second, the host sends `streamDiagnostics` and adapts stream settings:

- If congestion is detected, bitrate, quality, and target frame rate are reduced.
- After four clean diagnostic windows, bitrate, quality, and target frame rate are raised gradually.

Current adaptive limits:

- Bitrate: `1.2 Mbps...10 Mbps`, default `8 Mbps`.
- Quality: `0.42...0.76`, default `0.72`.
- Frame rate: `12...30 fps`, default `30 fps`.
- Key frame interval: 60 frames.

The iOS client can also send `requestKeyFrame` when local decoding needs one. Requests are rate-limited client-side to once per second.

## Developer Activity Events

The host watches agent event JSON files through `AgentEventBridgeService` and forwards recent activity to clients as `developerActivity` packets. The payload is `DeveloperActivityEvent`, with fields such as `kind`, `scheme`, `platform`, `bundleID`, `appPath`, `status`, `message`, `warningCount`, and `errorCount`.

These events are UI/status metadata. They are not required for the stream transport to function.

## Session Auditing

When a client authenticates, the Mac starts a local audit session. It records:

- Paired device ID and display name.
- Start/end time.
- Network kind and remote endpoint.
- Selected app/window names.
- Disconnect reason.

The audit log is local to the Mac and retained for 30 days. It does not record video frames, screenshots, keystrokes, pointer events, or window contents.

## Compatibility Notes

- Packet type `frame` and unknown-packet legacy image decoding are compatibility paths for pre-H.264 streaming.
- The host accepts a legacy bare `RemoteControlMessage` after authentication.
- Pairing QR decoding supports older full-payload and compact-payload forms.
- The protocol currently has no negotiated version beyond the pairing offer's `version = 1`. Adding a future packet or command should preserve unknown/legacy behavior or introduce explicit capability negotiation.

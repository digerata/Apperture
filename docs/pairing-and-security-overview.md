# Apperture Pairing and Security Overview

Apperture is designed to show and control windows from a Mac that the user owns. Before an iPhone can view or control Mac apps, the iPhone must be paired with the Mac.

## Pairing

Pairing starts on the Mac. The Mac owner chooses **Pair Phone**, and Apperture shows a QR code that expires after two minutes. The iPhone scans that QR code, sends a pairing request, and the Mac owner must explicitly approve the phone before access is allowed.

The QR code is short-lived and single-use. It is only used to prove that the iPhone is physically near the Mac at pairing time. A phone that has not been approved by the Mac owner cannot connect & receive the Mac window list, video stream, wallpaper, app icons, or input-control access.

## Remembered Devices

Both devices remember successful pairings. Pairing trust is stored in the device Keychain and is not synced through iCloud. A user can pair more than one Mac with an iPhone, and a Mac can trust more than one iPhone.

Either side can revoke a pairing:

- On Mac, revoking a phone prevents future access from that phone.
- On iPhone, forgetting a Mac removes the saved trust and connection details for that Mac.

## Private Network Access

Apperture allows paired devices to connect only over private networks such as local Wi-Fi, private VPNs, and Tailscale-style tailnet addresses. Public internet endpoints are rejected by the app.

This keeps the product focused on private access to the user’s own Mac.

## Active Sessions

When a paired iPhone connects, the Mac shows the trusted device state and can stop live view or revoke access. A paired iPhone may choose from streamable windows that are currently running on the Mac.

The Mac keeps a local 30-day session history for owner review. The history records which paired device connected, when it connected, the private network kind, and the selected app/window names. It does not record keystrokes, pointer movements, video frames, screenshots, or window contents.

## Permissions

Apperture asks for permissions only to provide the remote window experience:

- **Local Network** to discover and connect to the paired Mac.
- **Camera on iPhone** to scan the Mac pairing QR code.
- **Screen Recording on Mac** to capture the selected Mac window.
- **Accessibility on Mac** to send approved input to the selected app.

The Mac remains the host where apps run and render. The iPhone acts as a private viewer and controller for the user’s own Mac.

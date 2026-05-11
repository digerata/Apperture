# Apperture Security Audit Notes

This document describes the v1 pairing and session-security design for review.

## Security Goals

- Do not expose Mac host information to unpaired clients.
- Require physical proximity and Mac-owner approval before trust is stored.
- Store pairing trust locally in each device Keychain.
- Allow post-pairing connections only over private networks.
- Maintain a 30-day local Mac audit history without recording sensitive input or screen contents.

## Pairing Protocol

1. The Mac generates or loads a local device identity from Keychain.
2. The Mac owner chooses **Pair Phone**.
3. The Mac creates a `PairingOffer` with:
   - protocol version
   - offer ID
   - Mac device ID and display name
   - endpoint hints and stream port
   - 256-bit random secret
   - creation and expiry timestamps
4. The Mac encodes the offer as an `apperture://pair` QR payload.
5. The iPhone scans the QR code, validates expiry, generates or loads its local device identity, and sends a `PairingRequest`.
6. The pairing request includes an HMAC proof derived from the QR secret, offer ID, and phone device ID.
7. The Mac validates the proof and shows a pending approval prompt with the phone name and icon.
8. The Mac stores trust only if the owner chooses **Allow**.
9. The Mac returns a `PairingResponse`, and both sides save a `PairedDevice` record.

Pairing offers expire after 120 seconds and are cleared after approval, rejection, or cancellation.

## Authentication Gate

The stream listener accepts TCP connections, but it does not send host data immediately. The first client message must be a `RemoteClientEnvelope`:

- `pairingRequest`: accepted only while a valid pairing offer exists.
- `authRequest`: accepted only for a non-revoked paired device with a valid HMAC proof.
- `control`: accepted only after successful authentication.

Until authentication succeeds, the Mac does not send host info, window lists, app icons, wallpaper, developer activity, video frames, or stream diagnostics.

## Network Restrictions

Authenticated sessions are allowed only when the remote endpoint is classified as private:

- loopback
- RFC1918 IPv4
- IPv4 link-local
- IPv6 link-local or unique-local
- `100.64.0.0/10` for Tailscale-style tailnet addressing

Endpoints that cannot be classified as private are rejected.

## Stored Data

Keychain records:

- local device identity
- paired-device trust records
- shared pairing secret for each paired device

Mac Application Support records:

- 30-day local session audit history

Session audit records include:

- paired device ID and display name
- session start and end times
- private network kind
- remote address
- selected app/window names
- disconnect reason

Session audit records do not include:

- keystrokes
- pointer coordinates
- control messages
- video frames
- screenshots
- window contents

## Revocation

Revocation is local and authoritative for inbound access:

- If the Mac revokes a phone, that phone can no longer authenticate to the Mac.
- If the iPhone forgets a Mac, it removes local trust and stops connecting to that Mac.

Active sessions from a revoked phone should be closed immediately by the Mac host.

## Current Implementation Notes

The current implementation introduces pairing, authentication gates, Keychain-backed device trust, QR-based proximity pairing, private-network classification, and local audit records.

The next hardening step is to encrypt all post-authentication stream and control payloads with a session key derived from the paired-device secret and connection nonces, or to replace the TCP listener with mutual TLS using pinned local identities. The authentication gate is intentionally structured so that transport encryption can be added without changing the pairing UX or stored trust model.

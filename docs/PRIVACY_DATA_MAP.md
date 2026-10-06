# Oriel Privacy Data Map

## Default posture

Oriel is account-free and local-first. The checked-in implementation contains no analytics, advertising, crash-reporting, cloud AI, or model-training SDK. It includes an optional opaque-byte relay path, but the checked-in signed-bundle configuration does not name or enable a production relay endpoint. Local processing does not by itself make screen content harmless; screen capture and control remain high-sensitivity capabilities protected by macOS permissions and explicit session approval.

## Data inventory

| Datum | Source | Purpose | Processing/location | Persistence | External disclosure |
|---|---|---|---|---|---|
| Screen frames | User-selected Mac display through ScreenCaptureKit | Live remote view and local target detection | Mac memory; end-to-end encrypted direct or optional relayed transport | No repository feature persists frames | Paired iOS device; an enabled relay forwards opaque ciphertext only |
| Accessibility control label, role, bounds, enabled state | Frontmost app AX tree | Smart Tap semantic targets | Mac memory | No persistence | Paired iOS device only after transport/session approval; Smart Tap is not wired into the shipped remote canvas |
| Accessibility value text | AX tree | Not required | Deliberately not read/emitted | Never | Never |
| Secure text fields | AX tree | Not supported | Excluded by role/subrole sanitizer | Never | Never |
| OCR text and boxes | Apple Vision on a local frame | Smart Tap text targets | Mac memory | No persistence | Paired iOS device only if Smart Tap is later shipped; sensitive-looking text is marked ineligible |
| OpenCV region metadata | Local frame geometry | Future contour/region candidates | Not implemented in this slice; source type/ranking policy exists | None | None |
| Owned Core ML class result | Optional first-party model | Future known non-semantic objects | No model or weights ship in this slice; source is disabled unless an allowed class is configured | None | None |
| Pointer/key action type | Paired device | User-directed control | Mac memory | Redacted audit is required but not implemented yet | Mac companion; relayed packets remain end-to-end encrypted |
| Typed text payload | Paired device | User-directed typing | Mac memory only at execution | Must never be logged by default | None |
| Clipboard content | Paired device/Mac | Future clipboard feature | Capability exists in protocol only | Must never be logged by default | None |
| Session ID, device ID/name, approved capabilities, expiry/activity time | Pairing/session layer | Approval, authorization, expiry, revocation | Mac/iOS memory; long-lived identity keys are stored in Keychain | Durable device-revocation persistence remains incomplete | Paired devices only; relay cannot decrypt session packets |
| Pairing public key, nonce, signature, expiry | QR pairing payload | Device authentication and replay defense | Encoded payload and memory | Short-lived payload; long-lived identity keys are stored in Keychain | Shared between devices during pairing; relay receives only separate registration keys and a pairing-nonce digest |
| Relay source IP, connection timing, public registration key, room/tag pseudonyms, pairing-nonce digest, role, expiry, connection nonce, and byte counts | Mac/iOS outbound relay connections | Match one host and one client and forward opaque bytes | Relay process memory and ingress/network infrastructure when relay is enabled | Application code does not persist these fields; production ingress/log/retention configuration is not yet defined | Relay operator and network/ingress providers; never screen frames, typed text, device name, capabilities, or session keys in plaintext |
| Permission state, app/OS version, active-session count, capture-running state | Local Mac | Diagnostics | Local Mac | Exported only when user generates/copies report | User-controlled |
| Camera frames | iOS camera | Scan the pairing QR code | Processed on device by the scanner | Not persisted | None |
| Local-network service metadata | Bonjour | Find the Mac companion | Same LAN | Ephemeral discovery state | Same-LAN peers can observe advertised service |

## Explicit exclusions

- No analytics or success/cancel telemetry.
- No target labels, screen images, typed text, clipboard content, network addresses, device identifiers, pairing material, or secrets in diagnostics.
- No training on customer screen content.
- No screen content, typed text, clipboard content, device name, requested capabilities, or session keys are disclosed in plaintext to the optional relay.
- No production relay endpoint is configured in the checked-in signed-bundle metadata.
- No password, MFA/OTP, payment, permission-dialog, secure-input, or medical-record submission automation.

## App Privacy answer gate

Final App Store privacy answers must be based on the exact signed binary and production relay/ingress configuration, including whether a relay endpoint is enabled, who operates it, and its actual logging, retention, regional, and subprocessors posture. The current privacy manifests describe the checked-in build with no production relay endpoint and no analytics/collection SDK. A relay-enabled release remains blocked until a human re-audits this map and the App Privacy answers against deployed infrastructure. Any analytics, support upload, crash reporting, or cloud diagnostics change also requires re-audit before release.

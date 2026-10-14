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
| Voice input audio | iOS microphone, only between the user's two taps on the mic while Oriel is on screen | Turn the user's speech into text for the instruction field or the keyboard tray | Phone memory as 16 kHz PCM, then the paired Mac's memory over the end-to-end encrypted session; transcribed on the Mac by Whisper large-v3 on MLX | Neither device writes it; each holds one utterance (60 s at most) and drops it once transcribed or cancelled, or when the session ends | The user's own paired Mac only; an enabled relay forwards ciphertext; no speech service, Apple speech recognizer, or 67 Enterprise server |
| Voice transcript | The Mac's Whisper model | Text the user edits on the phone, then sends as an instruction or types on the Mac | Mac memory, then the phone's text field | Not persisted by voice input; the Mac's activity log records the utterance's length and transcription time, never the words | The phone; a model receives it only if the user sends it as an instruction |
| Speech model download | Hugging Face (`mlx-community/whisper-large-v3-mlx`, plus the matching tokenizer files) | Run Whisper on the Mac | The Mac companion's models folder, or a copy already in the user's Hugging Face cache | Until the user removes it in Settings, Assistant | Hugging Face sees the Mac's download request (IP address, time), not audio or text |
| Local-network service metadata | Bonjour | Find the Mac companion | Same LAN | Ephemeral discovery state | Same-LAN peers can observe advertised service |

## Explicit exclusions

- No analytics or success/cancel telemetry.
- No target labels, screen images, typed text, clipboard content, network addresses, device identifiers, pairing material, or secrets in diagnostics.
- No training on customer screen content or voice.
- No audio files, audio logs, cloud speech recognition, or recording in the background; the iOS app declares no background audio mode.
- No screen content, typed text, clipboard content, device name, requested capabilities, or session keys are disclosed in plaintext to the optional relay.
- No production relay endpoint is configured in the checked-in signed-bundle metadata.
- No password, MFA/OTP, payment, permission-dialog, secure-input, or medical-record submission automation.

## App Privacy answer gate

Final App Store privacy answers must be based on the exact signed binary and production relay/ingress configuration, including whether a relay endpoint is enabled, who operates it, and its actual logging, retention, regional, and subprocessors posture. The current privacy manifests describe the checked-in build with no production relay endpoint and no analytics/collection SDK. A relay-enabled release remains blocked until a human re-audits this map and the App Privacy answers against deployed infrastructure. Any analytics, support upload, crash reporting, or cloud diagnostics change also requires re-audit before release. Voice input keeps the iOS answer at Data Not Collected: the audio and its transcript travel only between the user's own two devices, end-to-end encrypted, and neither 67 Enterprise nor a third party can read them; the model download happens on the Mac companion, which is not an App Store binary.

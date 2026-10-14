# Oriel Phase 1 Threat Model

## Scope and assets

This model covers the checked-in native Phase 1 implementation: deterministic target ranking, macOS Accessibility/Vision providers, session authorization, InputBroker gating, permission onboarding, redacted diagnostics, iOS Smart Tap sequence checks, signed QR pairing, Keychain-backed identities, authenticated encrypted `Network.framework` transport, and the optional outbound opaque-byte relay path. Durable revocation, updater, release signing, physical-device proof, production relay infrastructure, and the redacted audit sink remain incomplete and require separate review.

Assets:

- Mac screen and application state
- Pointer/keyboard authority
- Typed and clipboard content
- Voice input audio from the phone's microphone, and its transcript
- Pairing/session keys and device trust
- User intent, approval, and the ability to stop control
- Relay routing metadata, service availability, and deployment supply chain

Trust boundaries:

1. macOS TCC permission boundary for Screen Recording and Accessibility.
2. Pairing boundary between the Mac and an iOS device.
3. Session-policy boundary before InputBroker/CGEvent injection.
4. Frame/target freshness boundary between Mac perception and iOS Smart Tap.
5. Optional relay boundary between each outbound app connection and the Python/WebSocket service. The relay is in scope when configured; hosted AI remains outside Phase 1.

## Threats and implemented controls

| Threat | Control in this slice | Residual risk / required follow-up |
|---|---|---|
| Unapproved device sends input | Signed pairing requests, a device identity derived from the client signing key, and `RemoteSessionPolicy` require explicit approval with a capability subset | Persist device revocation and complete physical-device adversarial testing |
| Capability escalation | Encrypted session packets and event types are checked against approved capabilities before InputBroker creates CGEvents | Expand end-to-end tests across every event capability |
| Stolen/replayed stale session | Short-lived signed pairing, nonce replay protection, encrypted directional counters, absolute/inactivity expiry, heartbeat closure, and revocation | Persist revocations securely; define production key rotation/recovery |
| User cannot stop control | Kill switch clears approvals, closes the live channel, and blocks authorization; menu-bar Stop Control is visible | Prove behavior with physical devices and TCC permissions |
| Tap executes against changed screen | Candidate and displayed frame sequences must match and target age must remain within policy | Define sequence transport semantics and monotonic-clock handling across devices |
| Ambiguous overlapping target is guessed | Ranker returns `ambiguous` for overlapping near ties; UI asks the user to choose | Tune thresholds using non-sensitive representative fixtures |
| Disabled, stale, future, or low-confidence target executes | Ranker and execution policy fail closed | Add integration fixtures from representative apps |
| Password or secure AX value leaks | Secure roles/subroles are excluded; AXValue is never read into emitted targets | Expand secure-role fixtures across third-party apps and languages |
| OCR exposes visible OTP/card content | Local classifier marks common secret/payment patterns sensitive and ranker excludes them | Pattern detection is conservative, not complete; direct handling remains required |
| Malicious/unproven object model | Core ML source is ineligible unless an owned class label is configured; no model/weights ship | Require dataset/license/provenance, accuracy, size, and privacy review before enabling |
| Permission UI is automated | Onboarding only explains status and opens the relevant System Settings pane | Manual user action remains mandatory |
| Diagnostics leaks content | Fixed redacted schema excludes content, labels, text, addresses, IDs, pairing material, and secrets | Add snapshot/schema tests before adding export/share UX |
| Silent or half-open peer retains authority | Encrypted heartbeat runs every two seconds after approval, marks the session stale after five seconds, and closes after fifteen seconds | Benchmark suspend/background/network-transition behavior on physical devices |
| Malicious or compromised relay reads/changes control traffic | Pairing request and session traffic remain end-to-end encrypted; signed registration, pairing-digest binding, counters, and authenticated packets fail closed | Relay still observes source IP, timing, public registration keys, room/tag pseudonyms, and byte counts and can deny service; complete external cryptographic/privacy review |
| Relay resource exhaustion or stale registration abuse | Pre-registration deadline, frame limits, connection/pending/replay caps, role uniqueness, expiry, and replay checks | Validate production ingress limits, monitoring, abuse response, and restart behavior under load |
| Dependency/license compromise | App targets use Apple frameworks/local Swift modules; the relay additionally depends on Python, cryptography, websockets, and its container/OS base | Keep direct dependencies declared and inventoried; pin and generate a resolved container/image SBOM plus vulnerability/license review for every deployed release |
| Microphone records without the user knowing, or in the background | iOS asks for the microphone on the first mic tap only; recording runs only between two taps while Oriel is on screen, goes on while the app is only inactive (Control Center, Notification Center, a system alert) and stops and drops the audio when Oriel enters the background, and the app declares no background audio mode; the mic shows only when the paired Mac offered voice input this session | Physical-device check of the mic indicator, interruptions (calls, Siri) and Bluetooth routes |
| Voice audio reaches someone other than the user's Mac | Audio goes only in `speechRequest` packets on the paired session, end-to-end encrypted like screen frames (a relay forwards ciphertext); no file, log, cloud speech service or Apple speech recognizer is used; the Mac transcribes it with a Whisper model on the Mac | The relay still sees timing and byte counts, so it can tell when someone speaks; padding is not implemented |
| Audio or transcripts persist after use | Phone and Mac hold one utterance in memory at most and drop it once it is transcribed or cancelled, or the session ends; the Mac's activity log records only the duration and timing, never words | Memory is not zeroed before release; a crash dump of either process could contain recent audio |
| Malformed or oversized speech traffic | Versioned payloads; 64 KB chunks, 60 seconds and in-order sequence per utterance, text and message size limits; a Mac that did not offer voice input ends a session that sends speech; unknown versions or kinds are answered as unsupported rather than parsed | Fuzz the speech decoders with the other session messages |
| Older peers break on new packets | Speech packets go only to a peer that showed it speaks them: the Mac offers in its approval (a key older phones skip), and answers only a phone that has asked; Oriel for Mac 1.0/1.0.1 and the Windows companion never receive one | Keep the `wire-v1-speech.json` vectors and legacy-decoder tests in CI |
| Untrusted speech model weights | Whisper large-v3 (MIT) from the `mlx-community/whisper-large-v3-mlx` Hugging Face repository over HTTPS into the companion's models folder, or a complete copy already in the user's Hugging Face cache; weights are tensors loaded by MLX, not code. The download is pinned to a commit of that repository (and of `openai/whisper-large-v3` for the tokenizer vocabulary), never a branch, and every file the engine loads (weights, config, vocabulary) is checked by SHA-256 against a hash built into the app before anything reads it, wherever the file came from. A file that fails is not loaded: Oriel's own copy is deleted, and a copy in another tool's cache is left untouched and passed over | Moving to a newer model needs its commit and hashes re-pinned in the app; the check and the read are separate steps on the same file, so someone who can already write to the user's home folder is out of scope |

## Prohibited action classes

The consumer build must fail closed for passwords/secrets, MFA/OTP entry, payments/checkouts, permission/security dialogs, secure login/FileVault, CAPTCHA, destructive confirmation, public sends/posts without exact approval, and medical-record signing/submission. Virtual HID, cliclick, arbitrary shell execution, general filesystem access, and unattended hosted control are out of scope.

## Logging and privacy requirements

Permitted audit fields are event category, coarse app identifier, approval decision, timestamp, and result. Logs must not contain screen content, target/OCR labels, typed text, clipboard content, full network addresses, device identifiers, pairing payloads, tokens, or secrets. The audit sink is not yet implemented; release is blocked until its schema and retention are tested.

## Security verification still required

- Independent review of mutual authentication, encrypted transport, replay handling, and downgrade resistance
- Secure Enclave feasibility, key migration/rotation, and device-revocation persistence
- Updater signature/channel and supply-chain review
- Fuzzing and size limits for all network messages
- End-to-end proof that stopped/revoked/expired sessions cannot reach CGEvent creation
- Signed sandbox runtime proof for any future Mac App Store target, plus notarized Developer ID binary review for the current fallback
- External review of pairing, transport, session authorization, logs, and privacy disclosures
- Resolved relay container SBOM, pinned base-image digest, dependency vulnerability scan, and production ingress/log-retention review

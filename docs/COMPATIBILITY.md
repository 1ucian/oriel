# Legacy LCU Frame Compatibility

Oriel's native Mac app replaces the Python `hermescap.py` stream helper while preserving the existing LCU filesystem contract. The native bridge starts once with the app, owns the cache through an atomic PID claim, and holds one ScreenCaptureKit stream under Oriel's stable bundle identity.

The bridge is off unless the owner turns it on: any process running as the user can read the screen through these files, under Oriel's Screen Recording permission. Turn it on only for a local tool you trust, then restart Oriel:

```text
defaults write com.67enterprise.oriel.mac localCaptureBridge.enabled -bool true
```

## Live compatibility directory

```text
~/.hermes/cache/oriel/
├── pid
├── frame.raw
├── raw
├── fps
├── req
└── latest.png
```

- `pid` identifies the current cache owner. Oriel refuses startup when another live process owns it and replaces only stale ownership.
- `raw` enables raw-frame publishing while its modification time is less than three seconds old.
- `fps` requests an exact clamped rate from 5 through 60 FPS while fresh; the bridge returns to 5 FPS after three seconds.
- `req` requests a PNG of the latest retained frame. The bridge writes `latest.png` atomically and keeps an unserved request pending until a frame exists.

## Wire format

`LegacySharedFrameWriter` writes a fixed 64-byte little-endian header followed by the complete BGRA pixel plane:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `UInt32` | Magic `0x48524331` (`HRC1`) |
| 4 | `UInt64` | Monotonic frame sequence |
| 12 | `UInt32` | Pixel width |
| 16 | `UInt32` | Pixel height |
| 20 | `UInt32` | Bytes per row |
| 24–63 | bytes | Reserved, zero-filled |
| 64+ | bytes | BGRA rows including row padding |

Pixels are synchronized before the sequence-bearing header is published. Consumers should still read the sequence before and after copying a frame and retry if it changed.

## Resource and lifecycle rules

- Raw pixel writes are disabled unless a live LCU consumer refreshes `raw`.
- PNG encoding happens only after `req` changes.
- Oriel performs no automatic capture retry loop after a TCC denial, preventing stacked permission prompts.
- Partial startup stops any opened stream and releases only Oriel's own PID claim.
- Normal app termination waits for bridge shutdown before allowing AppKit to exit.
- The Python LaunchAgent must remain loaded until the installed Oriel build has produced a valid HRC1 frame and a fresh `latest.png` through the live LCU reader. It can then be disabled, not deleted, for rollback.

## Verification

`LegacySharedFrameWriterTests` verifies the HRC1 bytes and pixel publication order. `LocalCaptureBridgeTests` verifies:

- atomic PID ownership and live-owner refusal;
- exact FPS forwarding and 5 FPS idle behavior;
- demand-gated raw publication;
- pending PNG requests;
- partial-start cleanup and owned-PID release.

Release rollout additionally requires a real installed-app TCC grant, a live LCU screenshot reporting `engine=hermescapture`, a raw-frame read with advancing sequence, and confirmation that Python is no longer running.

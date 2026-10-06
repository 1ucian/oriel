# Oriel

Your Mac, in your pocket, with a pair of hands.

This repository is the open part of Oriel: the Mac companion, the end-to-end encrypted
session protocol, the on-Mac assistant that operates the Mac from an instruction, and the
relay that lets a paired phone reach its Mac from anywhere. The iPhone and iPad app is
distributed separately and is not part of this repository.

## What is here

- `Apps/HermesCaptureMac`: the menu-bar companion. Screen capture, input, pairing and
  approval, the relay host, the assistant runtime and its policy gate, the activity log.
- `Sources/HermesCaptureProtocol`: pairing, reconnect, the encrypted session channel and the
  relay wire protocol, shared with the phone app.
- `Sources/HermesCaptureCore`: screen observation, the approval policy, display profiles.
- `relay/`: the relay server (Python, websockets), with its tests and a Dockerfile.
- `docs/`: models, threat model, privacy data map, compatibility, relay setup.

## Build

Requirements: macOS 15 or later, Xcode 26, XcodeGen.

```
swift test                       # protocol and core
xcodegen generate                # the Mac app project
xcodebuild -scheme HermesCaptureMac test
```

## The assistant

Two roles: a planner that turns an instruction into small steps and reads the final answer
off the screen, and an executor that takes one action per step. Opening an app and clicking
an entry the plan names happen without a model. Every action passes the approval policy:
secrets are never typed, and payments, deletions, sends, sign-ins, system dialogs and Return
in a chat app wait for the owner's approval on the phone. Models are the owner's choice:
Apple's on-device model, open models through Ollama (Qwen3.5 4B and 9B run on a 16 GB Mac),
or a provider with the owner's own key.

## License

Apache License 2.0; see `LICENSE` and `NOTICE`. "Oriel" and the Oriel icon are trademarks
of 67 Enterprise and are not licensed by the Apache License. Security reports: `SECURITY.md`.

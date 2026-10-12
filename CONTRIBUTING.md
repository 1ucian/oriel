# Contributing to Oriel

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Before you start

- **Security issues:** don't open a public issue. Follow [SECURITY.md](SECURITY.md) and report privately.
- **Bugs:** open an issue with the bug report form. Include the Mac companion version, the macOS version, the iOS app version and device, and the steps that reproduce it. Remove anything personal from logs and screenshots.
- **Ideas and bigger changes:** open an issue first, so we can agree on the shape before you write the code.

This repository holds the Mac companion, the shared Swift packages and the relay. The iPhone and iPad app is distributed through the App Store and is not part of it.

## Development

Requirements: macOS 15 or later on Apple silicon, Xcode 26, XcodeGen.

```
swift test                       # protocol and core packages
xcodegen generate                # the Mac app project
xcodebuild -scheme HermesCaptureMac test
```

The relay under `relay/` is Python (it needs `websockets`, see `relay/requirements.txt`); run its tests from the repository root with `python3 -m unittest discover -s relay/tests -t .`.

## Pull requests

- Keep each pull request to one change, and explain what it does and why.
- Add or update tests for the behavior you change. Run the suites above before you push.
- Match the style of the surrounding code.
- Never commit keys, tokens, personal data or screenshots of a real desktop.
- The privacy and safety rules are part of the product: secrets are never typed, sensitive steps wait for the owner's approval, and internet models never receive pixels unless the owner turns that on. A change to the policy gate, the pairing or the encrypted session needs tests that prove those rules still hold.

By contributing, you agree that your contribution is licensed under the Apache License 2.0, the license of this repository.

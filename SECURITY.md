# Security

Oriel is a remote control and an assistant for your own Mac. Its security model, in one
paragraph: a phone and a Mac pair once with a code shown on the Mac and an approval given on
the Mac; from then on every session is end-to-end encrypted between the two devices with keys
that never leave their keychains; the relay, when a user turns it on, forwards bytes it cannot
read; and the assistant acts only inside policy gates that refuse secrets outright and route
everything sensitive to the owner's phone for a per-step decision.

## Reporting a vulnerability

Report it privately through GitHub (this repository's Security tab, Report a vulnerability) or
email info@67enterprise.com, with a description, the versions involved (iOS app build, Mac
companion build), and steps to reproduce. Please do not open a public issue for a
vulnerability. We acknowledge reports within three business days, keep you informed while we
work on a fix, and credit you in the release notes if you want that. We do not run a bug
bounty.

## Scope

In scope: the iOS app, the Mac companion, the shared Swift packages in this repository, the
relay server under `relay/`, and the pairing, session and assistant protocols.

Out of scope: the models themselves (report model issues to their authors), third-party
model endpoints a user configures, and macOS or iOS platform issues (report those to Apple).

## What we consider a vulnerability

- A way to view or control a Mac without a valid pairing code and the owner's approval.
- A way to replay a pairing code, a reconnect handshake or a relay registration.
- A path by which screen pixels, typed text or the clipboard reach the relay in clear, or
  reach a model the owner did not configure.
- A way to make the assistant type a password, a one-time code or a card number, or to act
  on a system security dialog without the owner approving that step.
- A way to bypass the Mac's Stop Control.

## Keys and data

Pairing keys, trusted-device records and the relay reconnect route live in the data-protection
keychain of each device, scoped to the app's application identifier. Pairing codes are single
use and expire after sixty minutes. Reconnect handshakes are signed challenge and response with
replay protection on the Mac. Session traffic uses a per-session key agreed with Curve25519 and
authenticated encryption from Apple's CryptoKit.

## Supported versions

The current TestFlight or App Store build and the matching Mac companion release.

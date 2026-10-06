# Oriel outbound relay tunnel

## Current behavior and reason for this component

Before this tunnel, the Mac opened an inbound `NWListener`, advertised `_hermescapture._tcp` over Bonjour, and the iOS client browsed for ten seconds before opening a direct LAN TCP connection. That path cannot cross NAT or unrelated networks.

The relay path keeps Bonjour as a two-second optional fast path. When relay configuration is present, the Mac also opens an outbound secure WebSocket (`wss://`) to the relay and places a short-lived signed route in the QR offer. If Bonjour does not find the Mac, iOS opens its own outbound secure WebSocket to the same relay. No router configuration or inbound port is required on either device. Debug builds can set `ORIEL_FORCE_RELAY=1` to bypass Bonjour during relay-path QA; release builds ignore that switch.

## Security architecture

1. The Mac creates a random 192-bit room ID, 256-bit access key, and existing short-lived pairing nonce. The signed QR offer binds the relay host, port, room, access key, expiry, and Mac Curve25519 keys.
2. Neither peer sends the access key to the relay. Each derives the same HMAC-SHA256 rendezvous tag from the access key, room ID, and pairing nonce digest.
3. Host and client send fresh Ed25519-signed relay registrations over TLS. These keys provide self-asserted proof-of-possession for each registration; they are not certificates or account identities and are not independently linked to the pairing identities. Registrations bind role, room, rendezvous tag, pairing nonce digest, one-use connection nonce, and expiry.
4. The relay verifies signatures, expiry, field limits, role uniqueness, pairing-digest equality, and connection-nonce replay before matching exactly one host and one client.
5. On the relay path, the signed pairing request is encrypted client-to-Mac with a separate X25519/HKDF/ChaChaPoly handshake key. The relay can see the client X25519 public key and routing metadata, but not device name, requested capabilities, or client signing identity.
6. After pairing, the existing `SessionCipher` remains unchanged: X25519 + HKDF derives directional ChaChaPoly keys; authenticated counters reject replay; capability approval, heartbeat stale/closure, and explicit Stop Control remain end-to-end.
7. The relay only copies opaque bytes. It never receives a session key and cannot decrypt frames/input, forge authenticated packets, grant capabilities, or control the Mac.

A malicious relay can still observe source IPs, connection timing, public relay-registration keys, room/tag pseudonyms, and byte counts. It can delay, drop, replay ciphertext, or deny service. Authentication and counters make modification/replay fail closed, but availability is not cryptographically enforceable.

## Failure, reconnect, expiry, and closure

- Both apps retry failed outbound relay setup with capped exponential backoff and a fresh signed connection nonce on every attempt.
- Pre-registration connections are capped and must finish registration within ten seconds. Silent and partial sockets are closed and release capacity. Pending rooms and replay entries have separate explicit caps; capacity rejection happens before a replay entry is inserted.
- Registrations and QR routes expire after five minutes. The relay closes unmatched sockets at expiry and purges replay entries only after their expiry.
- Duplicate roles, mismatched pairing digests, stale registrations, bad signatures, oversized frames, early data, and nonce replay are rejected by closing the socket.
- EOF or failure on either side closes both relay sockets. The existing heartbeat then removes any remaining session authority.
- An established encrypted session is not silently resumed across a broken transport path. It closes fail-safe; the user starts a new short-lived pairing attempt. Session counters and approval are never reset behind the user's back.

## Mac configuration

The Mac companion enables relay mode when either configuration source supplies a host:

- Development/runtime: `ORIEL_RELAY_HOST`, optional `ORIEL_RELAY_PORT` (default `443`), and optional `ORIEL_RELAY_TRANSPORT` (`websocket` by default; `tcp` keeps the direct TLS relay mode).
- Signed production bundle: `OrielRelayHost`, optional `OrielRelayPort`, and optional `OrielRelayTransport` in the Mac app Info.plist.

These are public endpoint settings, not secrets. The iOS app does not need a baked relay address; it accepts only the address inside the Mac-signed, expiring QR offer.

If no relay host is configured, Oriel remains LAN-only and fully compatible with the existing Bonjour/direct TCP path. The HRC1 legacy shared-frame format and local helper are untouched.

## Relay deployment

Prerequisites:

- A dedicated DNS name, for example `relay.example.com`, reachable over HTTPS/WSS on port 443.
- A publicly trusted certificate at the HTTP ingress whose SAN matches that name. Self-signed certificates are intentionally rejected by Apple system trust.
- Python 3.11+ and `relay/requirements.txt`, or `relay/Dockerfile`.
- An HTTP ingress or tunnel that forwards only `wss://relay.example.com/oriel` to a loopback-only `ws://127.0.0.1:8765/oriel` origin with WebSocket upgrades enabled. The public client-to-ingress hop is TLS; the loopback origin hop is plaintext and is trusted only because it is not network-reachable. Do not bind this mode to `0.0.0.0` or route any other path.
- Explicit process and service bounds. Defaults are 2,048 active/pre-registration connections, 1,024 pending rooms, 4,096 replay entries, a 10-second registration deadline, and 6 MiB maximum WebSocket messages. Set `LimitNOFILE`, memory limits, ingress connection limits, and health checks consistently with those values. The service emits no room IDs, public keys, addresses, payloads, or pairing material to application logs.

Direct process example:

```bash
python3 -m venv /opt/oriel-relay/venv
/opt/oriel-relay/venv/bin/pip install -r relay/requirements.txt
/opt/oriel-relay/venv/bin/python -m relay.oriel_relay \
  --transport websocket \
  --host 127.0.0.1 --port 8765 \
  --allow-loopback-http-origin \
  --max-connections 2048 --max-pending 1024 \
  --max-replays 4096 --registration-timeout 10
```

`relay/oriel-relay.service.example` is a hardened loopback-origin systemd template. The ingress owns public TLS and must forward only `/oriel`. Raw TLS TCP remains available with `--transport tcp --tls-cert ... --tls-key ...` for a direct LAN/private-network deployment.

## Remaining production actions

This repository does not deploy infrastructure or change signed app configuration. A release owner must still:

1. Provision DNS, a public WSS 443 ingress, trusted TLS certificates, the exact `/oriel` route, firewall rules, monitoring, and capacity/abuse controls.
2. Deploy the relay from this commit and run the Python integration tests in CI.
3. Add `OrielRelayHost`, `OrielRelayPort`, and `OrielRelayTransport=websocket` to the signed Mac companion build configuration.
4. Build/install both apps and complete physical-device tests on separate cellular/Wi-Fi networks, including suspend, IP change, relay restart, expiry, replay, disconnect, and Stop Control.
5. Complete external cryptographic/privacy review and define certificate rotation, relay updates, retention, incident response, and regional availability.

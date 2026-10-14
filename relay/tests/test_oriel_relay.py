from __future__ import annotations

import asyncio
import base64
import json
import struct
import time
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.asyncio.client import connect as websocket_connect

from relay.oriel_relay import ACK, RelayConfig, RelayServer


def b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def registration(
    role: str,
    key: Ed25519PrivateKey,
    *,
    room: bytes = b"r" * 24,
    tag: bytes = b"t" * 32,
    pairing_digest: bytes = b"p" * 32,
    connection_nonce: bytes | None = None,
    expires_ms: int | None = None,
) -> bytes:
    public_key = key.public_key().public_bytes_raw()
    payload = {
        "connectionNonce": b64(connection_nonce or (role.encode() * 24)[:24]),
        "expiresAt": expires_ms or int((time.time() + 30) * 1000),
        "pairingNonceDigest": b64(pairing_digest),
        "protocolVersion": 1,
        "rendezvousTag": b64(tag),
        "role": role,
        "roomID": b64(room),
        "signingPublicKey": b64(public_key),
    }
    canonical = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    envelope = {
        "payload": payload,
        "signature": b64(key.sign(canonical)),
    }
    encoded = json.dumps(envelope, separators=(",", ":"), sort_keys=True).encode()
    return struct.pack(">I", len(encoded)) + encoded


class ScriptedTransport:
    def __init__(self, *messages: bytes | None):
        self.messages = list(messages)
        self.closed = False

    async def receive(self) -> bytes | None:
        if not self.messages:
            await asyncio.Future()
        return self.messages.pop(0)

    async def send(self, data: bytes) -> None:
        del data

    async def close(self) -> None:
        self.closed = True


@asynccontextmanager
async def running_relay(
    *,
    transport: str = "tcp",
    max_pending: int = 16,
    max_connections: int = 32,
    max_replays: int = 64,
    registration_timeout_seconds: float = 0.25,
):
    relay = RelayServer(
        RelayConfig(
            host="127.0.0.1",
            port=0,
            max_pending=max_pending,
            max_registration_bytes=8192,
            max_lifetime_seconds=60,
            max_connections=max_connections,
            max_replays=max_replays,
            registration_timeout_seconds=registration_timeout_seconds,
        )
    )
    if transport == "websocket":
        server = await relay.start_websocket(allow_insecure_test_transport=True)
    else:
        server = await relay.start(allow_insecure_test_transport=True)
    port = server.sockets[0].getsockname()[1]
    try:
        yield relay, port
    finally:
        await relay.close()


class RelayIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def open_registered(self, port: int, frame: bytes):
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(frame)
        await writer.drain()
        return reader, writer

    async def test_matches_outbound_peers_and_forwards_opaque_bytes_both_ways(self):
        async with running_relay() as (_, port):
            host_key = Ed25519PrivateKey.generate()
            client_key = Ed25519PrivateKey.generate()
            host_reader, host_writer = await self.open_registered(
                port, registration("host", host_key)
            )
            client_reader, client_writer = await self.open_registered(
                port, registration("client", client_key)
            )

            self.assertEqual(await asyncio.wait_for(host_reader.readexactly(4), 1), ACK)
            self.assertEqual(await asyncio.wait_for(client_reader.readexactly(4), 1), ACK)

            opaque_client_packet = b"\x00\xffciphertext-client"
            client_writer.write(opaque_client_packet)
            await client_writer.drain()
            self.assertEqual(
                await asyncio.wait_for(
                    host_reader.readexactly(len(opaque_client_packet)), 1
                ),
                opaque_client_packet,
            )

            opaque_host_packet = b"ciphertext-host\x00\x01"
            host_writer.write(opaque_host_packet)
            await host_writer.drain()
            self.assertEqual(
                await asyncio.wait_for(
                    client_reader.readexactly(len(opaque_host_packet)), 1
                ),
                opaque_host_packet,
            )

            client_writer.close()
            await client_writer.wait_closed()
            self.assertEqual(await asyncio.wait_for(host_reader.read(), 1), b"")
            host_writer.close()
            await host_writer.wait_closed()

    async def test_first_payload_after_ack_survives_match_read_race(self):
        original_wait = asyncio.wait

        async def delay_connection_handler_after_match(tasks, **kwargs):
            result = await original_wait(tasks, **kwargs)
            coroutine_names = {
                getattr(task.get_coro(), "__qualname__", "") for task in tasks
            }
            if any("Event.wait" in name for name in coroutine_names):
                await asyncio.sleep(0.05)
            return result

        with patch(
            "relay.oriel_relay.asyncio.wait",
            side_effect=delay_connection_handler_after_match,
        ):
            async with running_relay() as (_, port):
                host_reader, host_writer = await self.open_registered(
                    port,
                    registration("host", Ed25519PrivateKey.generate()),
                )
                client_reader, client_writer = await self.open_registered(
                    port,
                    registration("client", Ed25519PrivateKey.generate()),
                )

                self.assertEqual(
                    await asyncio.wait_for(client_reader.readexactly(4), 1),
                    ACK,
                )
                payload = b"first-encrypted-stream-packet"
                client_writer.write(payload)
                await client_writer.drain()

                self.assertEqual(
                    await asyncio.wait_for(host_reader.readexactly(4), 1),
                    ACK,
                )
                self.assertEqual(
                    await asyncio.wait_for(host_reader.readexactly(len(payload)), 1),
                    payload,
                )

                client_writer.close()
                await client_writer.wait_closed()
                host_writer.close()
                await host_writer.wait_closed()

    async def test_invalid_signature_and_expired_registration_are_rejected(self):
        async with running_relay() as (_, port):
            key = Ed25519PrivateKey.generate()
            invalid = bytearray(registration("host", key))
            invalid[-2] ^= 1
            reader, writer = await self.open_registered(port, bytes(invalid))
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
            writer.close()
            await writer.wait_closed()

            expired = registration(
                "host", key, expires_ms=int((time.time() - 1) * 1000)
            )
            reader, writer = await self.open_registered(port, expired)
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
            writer.close()
            await writer.wait_closed()

    async def test_rejected_registration_logs_sanitized_reason(self):
        async with running_relay() as (_, port):
            expired = registration(
                "client",
                Ed25519PrivateKey.generate(),
                expires_ms=int((time.time() - 1) * 1000),
            )
            with self.assertLogs("oriel-relay", level="WARNING") as captured:
                reader, writer = await self.open_registered(port, expired)
                self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
                writer.close()
                await writer.wait_closed()

            self.assertTrue(
                any(
                    "registration rejected: expired registration" in message
                    for message in captured.output
                )
            )

    async def test_pre_match_disconnect_cancels_all_wait_tasks(self):
        relay = RelayServer(RelayConfig(registration_timeout_seconds=0.25))
        transport = ScriptedTransport(
            registration("host", Ed25519PrivateKey.generate()),
            None,
        )
        created_tasks: list[asyncio.Task[object]] = []
        original_create_task = asyncio.create_task

        def track_task(coroutine):
            task = original_create_task(coroutine)
            created_tasks.append(task)
            return task

        with patch("relay.oriel_relay.asyncio.create_task", side_effect=track_task):
            await relay._handle_connection(transport)
        await asyncio.sleep(0)

        self.assertTrue(transport.closed)
        self.assertTrue(created_tasks)
        self.assertTrue(all(task.done() for task in created_tasks))

    async def test_connection_nonce_replay_and_role_collision_are_rejected(self):
        async with running_relay() as (relay, port):
            key = Ed25519PrivateKey.generate()
            nonce = b"n" * 24
            first_reader, first_writer = await self.open_registered(
                port, registration("host", key, connection_nonce=nonce)
            )
            await asyncio.sleep(0.05)
            replay_reader, replay_writer = await self.open_registered(
                port, registration("host", key, connection_nonce=nonce)
            )
            self.assertEqual(await asyncio.wait_for(replay_reader.read(), 1), b"")

            collision_reader, collision_writer = await self.open_registered(
                port, registration("host", Ed25519PrivateKey.generate())
            )
            self.assertEqual(await asyncio.wait_for(collision_reader.read(), 1), b"")
            self.assertEqual(relay.pending_count, 1)

            for writer in (first_writer, replay_writer, collision_writer):
                writer.close()
                await writer.wait_closed()
            self.assertEqual(await asyncio.wait_for(first_reader.read(), 1), b"")

    async def test_same_device_registering_again_replaces_its_stale_pending_slot(self):
        async with running_relay() as (relay, port):
            key = Ed25519PrivateKey.generate()
            stale_reader, stale_writer = await self.open_registered(
                port, registration("host", key, connection_nonce=b"a" * 24)
            )
            await asyncio.sleep(0.05)
            fresh_reader, fresh_writer = await self.open_registered(
                port, registration("host", key, connection_nonce=b"b" * 24)
            )
            # The earlier connection is closed and the room still waits, now on the fresh one.
            self.assertEqual(await asyncio.wait_for(stale_reader.read(), 1), b"")
            self.assertEqual(relay.pending_count, 1)

            client_reader, client_writer = await self.open_registered(
                port, registration("client", Ed25519PrivateKey.generate())
            )
            self.assertEqual(await asyncio.wait_for(fresh_reader.readexactly(len(ACK)), 1), ACK)
            self.assertEqual(await asyncio.wait_for(client_reader.readexactly(len(ACK)), 1), ACK)
            self.assertEqual(relay.pending_count, 0)

            for writer in (stale_writer, fresh_writer, client_writer):
                writer.close()
                await writer.wait_closed()

    async def test_mismatched_pairing_digest_does_not_pair(self):
        async with running_relay() as (_, port):
            host_reader, host_writer = await self.open_registered(
                port,
                registration("host", Ed25519PrivateKey.generate()),
            )
            client_reader, client_writer = await self.open_registered(
                port,
                registration(
                    "client",
                    Ed25519PrivateKey.generate(),
                    pairing_digest=b"x" * 32,
                ),
            )
            with self.assertRaises(asyncio.TimeoutError):
                await asyncio.wait_for(host_reader.readexactly(4), 0.1)
            self.assertEqual(await asyncio.wait_for(client_reader.read(), 1), b"")

            host_writer.close()
            client_writer.close()
            await host_writer.wait_closed()
            await client_writer.wait_closed()

    async def test_silent_and_partial_registration_connections_time_out(self):
        async with running_relay(registration_timeout_seconds=0.05) as (relay, port):
            silent_reader, silent_writer = await asyncio.open_connection(
                "127.0.0.1", port
            )
            partial_reader, partial_writer = await asyncio.open_connection(
                "127.0.0.1", port
            )
            partial_writer.write(struct.pack(">I", 100) + b"partial")
            await partial_writer.drain()

            self.assertEqual(
                await asyncio.wait_for(silent_reader.read(), 0.5), b""
            )
            self.assertEqual(
                await asyncio.wait_for(partial_reader.read(), 0.5), b""
            )
            await asyncio.sleep(0)
            self.assertEqual(relay.active_connection_count, 0)
            self.assertEqual(relay.pending_count, 0)

            silent_writer.close()
            partial_writer.close()
            await silent_writer.wait_closed()
            await partial_writer.wait_closed()

    async def test_pre_registration_capacity_is_bounded_and_recovers(self):
        async with running_relay(
            max_connections=1,
            registration_timeout_seconds=0.15,
        ) as (relay, port):
            first_reader, first_writer = await asyncio.open_connection(
                "127.0.0.1", port
            )
            await asyncio.sleep(0.02)
            self.assertEqual(relay.active_connection_count, 1)

            rejected_reader, rejected_writer = await asyncio.open_connection(
                "127.0.0.1", port
            )
            self.assertEqual(
                await asyncio.wait_for(rejected_reader.read(), 0.5), b""
            )
            self.assertEqual(relay.active_connection_count, 1)

            self.assertEqual(
                await asyncio.wait_for(first_reader.read(), 0.5), b""
            )
            await asyncio.sleep(0)
            self.assertEqual(relay.active_connection_count, 0)

            recovered_reader, recovered_writer = await self.open_registered(
                port,
                registration("host", Ed25519PrivateKey.generate()),
            )
            await asyncio.sleep(0.02)
            self.assertEqual(relay.active_connection_count, 1)
            recovered_writer.close()
            await recovered_writer.wait_closed()
            self.assertEqual(
                await asyncio.wait_for(recovered_reader.read(), 0.5), b""
            )

            for writer in (first_writer, rejected_writer):
                writer.close()
                await writer.wait_closed()

    async def test_capacity_rejections_do_not_consume_replay_budget(self):
        async with running_relay(max_pending=1, max_replays=2) as (relay, port):
            first_reader, first_writer = await self.open_registered(
                port,
                registration(
                    "host",
                    Ed25519PrivateKey.generate(),
                    room=b"a" * 24,
                    tag=b"a" * 32,
                ),
            )
            await asyncio.sleep(0.02)
            self.assertEqual(relay.pending_count, 1)
            self.assertEqual(relay.replay_count, 1)

            rejected_reader, rejected_writer = await self.open_registered(
                port,
                registration(
                    "host",
                    Ed25519PrivateKey.generate(),
                    room=b"b" * 24,
                    tag=b"b" * 32,
                ),
            )
            self.assertEqual(await asyncio.wait_for(rejected_reader.read(), 1), b"")
            self.assertEqual(relay.pending_count, 1)
            self.assertEqual(relay.replay_count, 1)

            first_writer.close()
            await first_writer.wait_closed()
            self.assertEqual(await asyncio.wait_for(first_reader.read(), 1), b"")
            rejected_writer.close()
            await rejected_writer.wait_closed()

    async def test_replay_capacity_is_explicitly_bounded(self):
        async with running_relay(max_pending=2, max_replays=1) as (relay, port):
            first_reader, first_writer = await self.open_registered(
                port,
                registration(
                    "host",
                    Ed25519PrivateKey.generate(),
                    room=b"a" * 24,
                    tag=b"a" * 32,
                ),
            )
            await asyncio.sleep(0.02)

            rejected_reader, rejected_writer = await self.open_registered(
                port,
                registration(
                    "host",
                    Ed25519PrivateKey.generate(),
                    room=b"b" * 24,
                    tag=b"b" * 32,
                ),
            )
            self.assertEqual(await asyncio.wait_for(rejected_reader.read(), 1), b"")
            self.assertEqual(relay.replay_count, 1)
            self.assertEqual(relay.pending_count, 1)

            first_writer.close()
            rejected_writer.close()
            await first_writer.wait_closed()
            await rejected_writer.wait_closed()
            self.assertEqual(await asyncio.wait_for(first_reader.read(), 1), b"")

    async def test_websocket_server_disables_periodic_ping_for_network_framework_clients(self):
        relay = RelayServer(RelayConfig(host="127.0.0.1", port=0))
        with patch(
            "relay.oriel_relay.serve",
            new_callable=AsyncMock,
        ) as mocked_serve:
            mocked_serve.return_value = object()
            await relay.start_websocket(allow_insecure_test_transport=True)

        await_args = mocked_serve.await_args
        self.assertIsNotNone(await_args)
        kwargs = await_args.kwargs if await_args is not None else {}
        self.assertIn("ping_interval", kwargs)
        self.assertIsNone(kwargs["ping_interval"])

    async def test_websocket_relay_preserves_binary_messages_and_ack_boundary(self):
        async with running_relay(transport="websocket") as (_, port):
            async with websocket_connect(
                f"ws://127.0.0.1:{port}/oriel"
            ) as host, websocket_connect(
                f"ws://127.0.0.1:{port}/oriel"
            ) as client:
                await host.send(registration("host", Ed25519PrivateKey.generate()))
                await client.send(registration("client", Ed25519PrivateKey.generate()))

                self.assertEqual(await asyncio.wait_for(host.recv(), 1), ACK)
                self.assertEqual(await asyncio.wait_for(client.recv(), 1), ACK)

                first_payload = b"first-encrypted-websocket-packet"
                await client.send(first_payload)
                self.assertEqual(await asyncio.wait_for(host.recv(), 1), first_payload)

                response = b"opaque-response\x00\xff"
                await host.send(response)
                self.assertEqual(await asyncio.wait_for(client.recv(), 1), response)

    async def test_websocket_rejects_text_and_early_binary_data(self):
        async with running_relay(transport="websocket") as (_, port):
            async with websocket_connect(f"ws://127.0.0.1:{port}/oriel") as text_peer:
                await text_peer.send("not-binary")
                with self.assertRaises(Exception):
                    await asyncio.wait_for(text_peer.recv(), 1)

            async with websocket_connect(f"ws://127.0.0.1:{port}/oriel") as early_peer:
                await early_peer.send(
                    registration("host", Ed25519PrivateKey.generate())
                )
                await early_peer.send(b"early-data")
                with self.assertRaises(Exception):
                    await asyncio.wait_for(early_peer.recv(), 1)


if __name__ == "__main__":
    unittest.main()

"""Oriel opaque rendezvous relay.

The relay authenticates short-lived, identity-signed registrations, matches one host
with one client, and copies bytes without interpreting the end-to-end Oriel stream.
Production startup requires TLS. Plain TCP is available only to the loopback test
harness through an explicit flag.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import signal
import ssl
import struct
import time
from dataclasses import dataclass, field
from typing import Any, Protocol

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

ACK = b"OROK"
_PROTOCOL_VERSION = 1
_LOG = logging.getLogger("oriel-relay")


@dataclass(frozen=True)
class RelayConfig:
    host: str = "127.0.0.1"
    port: int = 8443
    max_pending: int = 1024
    max_registration_bytes: int = 8192
    max_lifetime_seconds: int = 600
    max_connections: int = 2048
    max_replays: int = 4096
    registration_timeout_seconds: float = 10.0
    max_websocket_message_bytes: int = 6 * 1024 * 1024


@dataclass(frozen=True)
class Registration:
    role: str
    room_id: bytes
    rendezvous_tag: bytes
    pairing_nonce_digest: bytes
    signing_public_key: bytes
    connection_nonce: bytes
    expires_at: float

    @property
    def room_key(self) -> bytes:
        return hashlib.sha256(self.room_id + self.rendezvous_tag).digest()

    @property
    def replay_key(self) -> bytes:
        return hashlib.sha256(
            self.signing_public_key + self.connection_nonce
        ).digest()


class RelayTransport(Protocol):
    async def receive(self) -> bytes | None: ...
    async def send(self, data: bytes) -> None: ...
    async def close(self) -> None: ...


@dataclass(eq=False)
class TCPTransport:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter

    async def receive(self) -> bytes | None:
        data = await self.reader.read(64 * 1024)
        return data or None

    async def send(self, data: bytes) -> None:
        self.writer.write(data)
        await self.writer.drain()

    async def close(self) -> None:
        await _close_writer(self.writer)


@dataclass(eq=False)
class WebSocketTransport:
    socket: ServerConnection

    async def receive(self) -> bytes | None:
        try:
            data = await self.socket.recv()
        except ConnectionClosed:
            return None
        if isinstance(data, str):
            raise RegistrationError("text websocket messages are not allowed")
        return bytes(data)

    async def send(self, data: bytes) -> None:
        await self.socket.send(data)

    async def close(self) -> None:
        await self.socket.close()


@dataclass
class Peer:
    registration: Registration
    transport: RelayTransport
    ready_for_bridge: bool = False


@dataclass
class PendingRoom:
    pairing_nonce_digest: bytes
    host: Peer | None = None
    client: Peer | None = None
    paired: asyncio.Event = field(default_factory=asyncio.Event)
    done: asyncio.Future[None] | None = None
    bridge_started: bool = False
    aborted: bool = False


class RegistrationError(ValueError):
    pass


class RelayServer:
    def __init__(self, config: RelayConfig) -> None:
        self.config = config
        self._server: Any | None = None
        self._pending: dict[bytes, PendingRoom] = {}
        self._replays: dict[bytes, float] = {}
        self._lock = asyncio.Lock()
        self._bridge_tasks: set[asyncio.Task[None]] = set()
        self._connections: set[RelayTransport] = set()
        self._closing = False

    @property
    def pending_count(self) -> int:
        return len(self._pending)

    @property
    def active_connection_count(self) -> int:
        return len(self._connections)

    @property
    def replay_count(self) -> int:
        return len(self._replays)

    async def start(
        self,
        *,
        ssl_context: ssl.SSLContext | None = None,
        allow_insecure_test_transport: bool = False,
    ) -> asyncio.AbstractServer:
        if ssl_context is None and not allow_insecure_test_transport:
            raise ValueError("TLS is required for production relay startup")
        self._server = await asyncio.start_server(
            self._handle_tcp_connection,
            self.config.host,
            self.config.port,
            ssl=ssl_context,
            limit=self.config.max_registration_bytes + 4,
        )
        return self._server

    async def start_websocket(
        self,
        *,
        ssl_context: ssl.SSLContext | None = None,
        allow_insecure_test_transport: bool = False,
        allow_loopback_http_origin: bool = False,
    ) -> Any:
        if ssl_context is None and not (
            allow_insecure_test_transport
            or allow_loopback_http_origin and _is_loopback_host(self.config.host)
        ):
            raise ValueError(
                "WebSocket relay requires TLS or an explicitly allowed loopback HTTP origin"
            )
        self._server = await serve(
            self._handle_websocket_connection,
            self.config.host,
            self.config.port,
            ssl=ssl_context,
            open_timeout=self.config.registration_timeout_seconds,
            ping_interval=None,
            max_size=self.config.max_websocket_message_bytes,
            compression=None,
        )
        return self._server

    async def _handle_tcp_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        await self._handle_connection(TCPTransport(reader, writer))

    async def _handle_websocket_connection(self, socket: ServerConnection) -> None:
        if socket.request is None or socket.request.path != "/oriel":
            await socket.close(code=1008, reason="invalid relay path")
            return
        await self._handle_connection(WebSocketTransport(socket))

    async def close(self) -> None:
        async with self._lock:
            self._closing = True
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        async with self._lock:
            transports = list(self._connections)
        await asyncio.gather(
            *(transport.close() for transport in transports),
            return_exceptions=True,
        )
        tasks = list(self._bridge_tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        async with self._lock:
            self._pending.clear()
            self._replays.clear()
            self._connections.clear()

    async def _handle_connection(self, transport: RelayTransport) -> None:
        peer: Peer | None = None
        room: PendingRoom | None = None
        room_key: bytes | None = None
        paired_wait: asyncio.Task[bool] | None = None
        premature_read: asyncio.Task[bytes | None] | None = None
        if not await self._acquire_connection(transport):
            await transport.close()
            return
        try:
            frame = await asyncio.wait_for(
                self._read_registration_frame(transport),
                timeout=self.config.registration_timeout_seconds,
            )
            registration = _decode_and_verify_registration(
                frame,
                now=time.time(),
                max_lifetime_seconds=self.config.max_lifetime_seconds,
            )
            peer = Peer(registration, transport)
            room_key, room = await self._register(peer)

            paired_wait = asyncio.create_task(room.paired.wait())
            premature_read = asyncio.create_task(transport.receive())
            done, pending = await asyncio.wait(
                {paired_wait, premature_read},
                timeout=max(0.0, registration.expires_at - time.time()),
                return_when=asyncio.FIRST_COMPLETED,
            )
            if not done:
                for task in pending:
                    task.cancel()
                await asyncio.gather(paired_wait, return_exceptions=True)
                await asyncio.gather(premature_read, return_exceptions=True)
                raise RegistrationError("registration expired while waiting")
            if premature_read in done:
                data = premature_read.result()
                if data is not None or not room.paired.is_set():
                    raise RegistrationError("peer sent data or closed before match")
            for task in pending:
                task.cancel()
            await asyncio.gather(paired_wait, return_exceptions=True)
            await asyncio.gather(premature_read, return_exceptions=True)

            await self._mark_ready_for_bridge(room, peer)
            if room.done is not None:
                await asyncio.shield(room.done)
        except RegistrationError as error:
            _LOG.warning("registration rejected: %s", error)
        except (
            asyncio.IncompleteReadError,
            asyncio.TimeoutError,
            ConnectionClosed,
            ConnectionError,
            OSError,
        ):
            pass
        finally:
            wait_tasks: list[asyncio.Task[Any]] = []
            if paired_wait is not None:
                wait_tasks.append(paired_wait)
            if premature_read is not None:
                wait_tasks.append(premature_read)
            for task in wait_tasks:
                if not task.done():
                    task.cancel()
            if wait_tasks:
                await asyncio.gather(*wait_tasks, return_exceptions=True)
            if room_key is not None and room is not None and not room.paired.is_set():
                await self._remove_pending(room_key, room, peer)
            if (
                room is not None
                and room.paired.is_set()
                and peer is not None
                and not peer.ready_for_bridge
            ):
                await self._abort_paired(room)
            if room is None or not room.paired.is_set():
                await transport.close()
            await self._release_connection(transport)

    async def _acquire_connection(self, transport: RelayTransport) -> bool:
        async with self._lock:
            if self._closing or len(self._connections) >= self.config.max_connections:
                return False
            self._connections.add(transport)
            return True

    async def _release_connection(self, transport: RelayTransport) -> None:
        async with self._lock:
            self._connections.discard(transport)

    async def _read_registration_frame(self, transport: RelayTransport) -> bytes:
        if isinstance(transport, TCPTransport):
            prefix = await transport.reader.readexactly(4)
            (length,) = struct.unpack(">I", prefix)
            if length <= 0 or length > self.config.max_registration_bytes:
                raise RegistrationError("invalid registration length")
            return await transport.reader.readexactly(length)

        message = await transport.receive()
        if message is None or len(message) < 4:
            raise RegistrationError("incomplete registration frame")
        (length,) = struct.unpack(">I", message[:4])
        if length <= 0 or length > self.config.max_registration_bytes:
            raise RegistrationError("invalid registration length")
        if len(message) != length + 4:
            raise RegistrationError("registration must be one binary websocket message")
        return message[4:]

    async def _register(self, peer: Peer) -> tuple[bytes, PendingRoom]:
        registration = peer.registration
        now = time.time()
        async with self._lock:
            self._replays = {
                key: expiry for key, expiry in self._replays.items() if expiry > now
            }
            if registration.replay_key in self._replays:
                raise RegistrationError("registration replay")

            room_key = registration.room_key
            room = self._pending.get(room_key)
            if room is None:
                if len(self._pending) >= self.config.max_pending:
                    raise RegistrationError("relay capacity reached")
            elif room.pairing_nonce_digest != registration.pairing_nonce_digest:
                raise RegistrationError("pairing binding mismatch")

            # A device that registers again while its earlier registration still waits takes the slot over: that
            # connection is usually already dead (a network change leaves it open on this side), and refusing the
            # new one would leave the other device nothing to meet until it expired. Only the same signing key may
            # do this; the replay check above already requires a fresh connection nonce.
            stale: Peer | None = None
            if registration.role == "host":
                if room is not None and room.host is not None:
                    if room.host.registration.signing_public_key != registration.signing_public_key:
                        raise RegistrationError("host already registered")
                    stale = room.host
            elif room is not None and room.client is not None:
                if room.client.registration.signing_public_key != registration.signing_public_key:
                    raise RegistrationError("client already registered")
                stale = room.client

            if len(self._replays) >= self.config.max_replays:
                raise RegistrationError("replay capacity reached")
            self._replays[registration.replay_key] = registration.expires_at

            if room is None:
                room = PendingRoom(registration.pairing_nonce_digest)
                self._pending[room_key] = room
            if registration.role == "host":
                room.host = peer
            else:
                room.client = peer
            if stale is not None:
                _LOG.info("registration replaced a pending one from the same device")
                asyncio.get_running_loop().create_task(stale.transport.close())

            if room.host is not None and room.client is not None:
                self._pending.pop(room_key, None)
                loop = asyncio.get_running_loop()
                room.done = loop.create_future()
                room.paired.set()
            return room_key, room

    async def _mark_ready_for_bridge(self, room: PendingRoom, peer: Peer) -> None:
        async with self._lock:
            if room.aborted:
                return
            peer.ready_for_bridge = True
            if (
                room.host is not None
                and room.client is not None
                and room.host.ready_for_bridge
                and room.client.ready_for_bridge
                and not room.bridge_started
            ):
                room.bridge_started = True
                task = asyncio.create_task(self._bridge(room))
                self._bridge_tasks.add(task)
                task.add_done_callback(self._bridge_finished)

    def _bridge_finished(self, task: asyncio.Task[None]) -> None:
        self._bridge_tasks.discard(task)
        if task.cancelled():
            return
        error = task.exception()
        if error is not None:
            _LOG.warning("bridge task failed: %s", type(error).__name__)

    async def _abort_paired(self, room: PendingRoom) -> None:
        async with self._lock:
            if room.aborted:
                peers: tuple[Peer, ...] = ()
            else:
                room.aborted = True
                if room.done is not None and not room.done.done():
                    room.done.set_result(None)
                peers = tuple(
                    peer for peer in (room.host, room.client) if peer is not None
                )
        await asyncio.gather(
            *(peer.transport.close() for peer in peers),
            return_exceptions=True,
        )

    async def _remove_pending(
        self,
        room_key: bytes,
        room: PendingRoom,
        peer: Peer | None,
    ) -> None:
        async with self._lock:
            if self._pending.get(room_key) is not room:
                return
            if peer is room.host:
                room.host = None
            if peer is room.client:
                room.client = None
            if room.host is None and room.client is None:
                self._pending.pop(room_key, None)

    async def _bridge(self, room: PendingRoom) -> None:
        assert room.host is not None and room.client is not None
        assert room.done is not None
        host = room.host
        client = room.client
        try:
            await asyncio.gather(
                host.transport.send(ACK),
                client.transport.send(ACK),
            )

            host_to_client = asyncio.create_task(
                _copy_transport(host.transport, client.transport)
            )
            client_to_host = asyncio.create_task(
                _copy_transport(client.transport, host.transport)
            )
            done, pending = await asyncio.wait(
                {host_to_client, client_to_host},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            await asyncio.gather(*done, *pending, return_exceptions=True)
        finally:
            await asyncio.gather(
                host.transport.close(),
                client.transport.close(),
                return_exceptions=True,
            )
            if not room.done.done():
                room.done.set_result(None)


def _decode_and_verify_registration(
    encoded: bytes,
    *,
    now: float,
    max_lifetime_seconds: int,
) -> Registration:
    try:
        envelope = json.loads(encoded)
        if set(envelope) != {"payload", "signature"}:
            raise RegistrationError("invalid registration envelope")
        payload = envelope["payload"]
        required = {
            "connectionNonce",
            "expiresAt",
            "pairingNonceDigest",
            "protocolVersion",
            "rendezvousTag",
            "role",
            "roomID",
            "signingPublicKey",
        }
        if not isinstance(payload, dict) or set(payload) != required:
            raise RegistrationError("invalid registration payload")
        canonical = json.dumps(
            payload, separators=(",", ":"), sort_keys=True
        ).encode()
        public_key = _decode_base64(payload["signingPublicKey"], 32, 32)
        signature = _decode_base64(envelope["signature"], 64, 64)
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, canonical)

        if payload["protocolVersion"] != _PROTOCOL_VERSION:
            raise RegistrationError("unsupported relay protocol")
        role = payload["role"]
        if role not in {"host", "client"}:
            raise RegistrationError("invalid role")
        expires_at = _milliseconds_to_seconds(payload["expiresAt"])
        if expires_at <= now or expires_at - now > max_lifetime_seconds:
            raise RegistrationError("expired registration")

        return Registration(
            role=role,
            room_id=_decode_base64(payload["roomID"], 16, 64),
            rendezvous_tag=_decode_base64(payload["rendezvousTag"], 32, 32),
            pairing_nonce_digest=_decode_base64(
                payload["pairingNonceDigest"], 32, 32
            ),
            signing_public_key=public_key,
            connection_nonce=_decode_base64(
                payload["connectionNonce"], 16, 64
            ),
            expires_at=expires_at,
        )
    except (KeyError, TypeError, ValueError, InvalidSignature, json.JSONDecodeError) as error:
        if isinstance(error, RegistrationError):
            raise
        raise RegistrationError("invalid registration") from error


def _decode_base64(value: Any, minimum: int, maximum: int) -> bytes:
    if not isinstance(value, str):
        raise RegistrationError("invalid base64 field")
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as error:
        raise RegistrationError("invalid base64 field") from error
    if not minimum <= len(decoded) <= maximum:
        raise RegistrationError("invalid field length")
    return decoded


def _milliseconds_to_seconds(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RegistrationError("invalid expiry")
    return float(value) / 1000.0


async def _copy_transport(
    source: RelayTransport,
    destination: RelayTransport,
) -> None:
    while True:
        chunk = await source.receive()
        if chunk is None:
            return
        await destination.send(chunk)


def _is_loopback_host(host: str) -> bool:
    return host in {"127.0.0.1", "::1", "localhost"}


async def _close_writer(writer: asyncio.StreamWriter) -> None:
    if writer.is_closing():
        return
    writer.close()
    try:
        await writer.wait_closed()
    except (ConnectionError, OSError):
        pass


def _tls_context(cert_file: str, key_file: str) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert_file, keyfile=key_file)
    return context


async def _run(args: argparse.Namespace) -> None:
    relay = RelayServer(
        RelayConfig(
            host=args.host,
            port=args.port,
            max_pending=args.max_pending,
            max_connections=args.max_connections,
            max_replays=args.max_replays,
            registration_timeout_seconds=args.registration_timeout,
        )
    )
    if bool(args.tls_cert) != bool(args.tls_key):
        raise ValueError("--tls-cert and --tls-key must be supplied together")
    tls_context = (
        _tls_context(args.tls_cert, args.tls_key)
        if args.tls_cert and args.tls_key
        else None
    )
    if args.transport == "websocket":
        server = await relay.start_websocket(
            ssl_context=tls_context,
            allow_loopback_http_origin=args.allow_loopback_http_origin,
        )
    else:
        server = await relay.start(ssl_context=tls_context)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_name in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signal_name, stop.set)
    sockets = getattr(server, "sockets", None) or []
    _LOG.info("relay ready on %s socket(s)", len(sockets))
    await stop.wait()
    await relay.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Oriel opaque rendezvous relay")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument(
        "--transport", choices=("tcp", "websocket"), default="websocket"
    )
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    parser.add_argument(
        "--allow-loopback-http-origin",
        action="store_true",
        help="allow plain ws only on loopback behind a TLS-terminating HTTP tunnel",
    )
    parser.add_argument("--max-pending", type=int, default=1024)
    parser.add_argument("--max-connections", type=int, default=2048)
    parser.add_argument("--max-replays", type=int, default=4096)
    parser.add_argument("--registration-timeout", type=float, default=10.0)
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args()
    logging.basicConfig(level=args.log_level)
    asyncio.run(_run(args))


if __name__ == "__main__":
    main()

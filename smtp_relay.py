#!/usr/bin/env python3
"""
SMTP Tunnel Relay (Server A).

Maintains one authenticated SMTP tunnel to Server B, and forwards local TCP
inbound ports to remote targets over multiplexed binary channels.
"""

import argparse
import asyncio
import logging
import os
import ssl
import struct
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from common import generate_auth_token, load_config


logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("smtp-tunnel-relay")


FRAME_DATA = 0x01
FRAME_CONNECT = 0x02
FRAME_CONNECT_OK = 0x03
FRAME_CONNECT_FAIL = 0x04
FRAME_CLOSE = 0x05
FRAME_HEADER_SIZE = 5


def make_frame(frame_type: int, channel_id: int, payload: bytes = b"") -> bytes:
    return struct.pack(">BHH", frame_type, channel_id, len(payload)) + payload


def make_connect_payload(host: str, port: int) -> bytes:
    hb = host.encode("utf-8")
    return struct.pack(">B", len(hb)) + hb + struct.pack(">H", port)


@dataclass
class ForwardRule:
    listen_host: str
    listen_port: int
    target_host: str
    target_port: int


@dataclass
class Channel:
    channel_id: int
    local_reader: asyncio.StreamReader
    local_writer: asyncio.StreamWriter
    connected: bool = False


class TunnelConnection:
    def __init__(
        self,
        server_host: str,
        server_port: int,
        username: str,
        secret: str,
        tls_server_name: Optional[str] = None,
        ca_cert: Optional[str] = None,
    ):
        self.server_host = server_host
        self.server_port = server_port
        self.username = username
        self.secret = secret
        self.tls_server_name = tls_server_name
        self.ca_cert = ca_cert

        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.connected = False
        self.connected_event = asyncio.Event()
        self.write_lock = asyncio.Lock()
        self.channel_lock = asyncio.Lock()
        self.next_channel_id = 1

        self.channels: Dict[int, Channel] = {}
        self.connect_waiters: Dict[int, asyncio.Future] = {}

    async def run_forever(self):
        backoff = 2
        while True:
            try:
                await self._connect()
                backoff = 2
                await self._receiver_loop()
            except Exception as exc:
                logger.warning("Tunnel disconnected: %s", exc)
            finally:
                await self._mark_disconnected()
            logger.info("Reconnecting in %ss", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)

    async def _connect(self):
        logger.info("Connecting to %s:%s", self.server_host, self.server_port)
        self.reader, self.writer = await asyncio.open_connection(self.server_host, self.server_port)
        ok = await self._smtp_handshake()
        if not ok:
            raise RuntimeError("SMTP handshake/auth failed")
        self.connected = True
        self.connected_event.set()
        logger.info("Tunnel connected (binary mode)")

    async def _smtp_handshake(self) -> bool:
        line = await self._read_line()
        if not line or not line.startswith("220"):
            return False

        await self._send_line("EHLO relay.local")
        if not await self._expect_250():
            return False

        await self._send_line("STARTTLS")
        line = await self._read_line()
        if not line or not line.startswith("220"):
            return False

        await self._upgrade_tls()

        await self._send_line("EHLO relay.local")
        if not await self._expect_250():
            return False

        token = generate_auth_token(self.username, self.secret)
        await self._send_line(f"AUTH PLAIN {token}")
        line = await self._read_line()
        if not line or not line.startswith("235"):
            logger.error("AUTH failed: %s", line)
            return False

        await self._send_line("BINARY")
        line = await self._read_line()
        if not line or not line.startswith("299"):
            logger.error("BINARY failed: %s", line)
            return False
        return True

    async def _upgrade_tls(self):
        ctx = ssl.create_default_context()
        if self.ca_cert and os.path.exists(self.ca_cert):
            ctx.load_verify_locations(self.ca_cert)
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

        transport = self.writer.transport
        protocol = self.writer._protocol  # pylint: disable=protected-access
        loop = asyncio.get_event_loop()
        server_name = self.tls_server_name or self.server_host
        new_transport = await loop.start_tls(transport, protocol, ctx, server_hostname=server_name)
        self.writer._transport = new_transport  # pylint: disable=protected-access
        self.reader._transport = new_transport  # pylint: disable=protected-access

    async def _send_line(self, line: str):
        self.writer.write(f"{line}\r\n".encode())
        await self.writer.drain()

    async def _read_line(self) -> Optional[str]:
        try:
            data = await asyncio.wait_for(self.reader.readline(), timeout=60.0)
            if not data:
                return None
            return data.decode("utf-8", errors="replace").strip()
        except Exception:
            return None

    async def _expect_250(self) -> bool:
        while True:
            line = await self._read_line()
            if not line:
                return False
            if line.startswith("250 "):
                return True
            if line.startswith("250-"):
                continue
            return False

    async def _receiver_loop(self):
        buf = b""
        while self.connected:
            chunk = await self.reader.read(65536)
            if not chunk:
                break
            buf += chunk

            while len(buf) >= FRAME_HEADER_SIZE:
                frame_type, channel_id, payload_len = struct.unpack(">BHH", buf[:FRAME_HEADER_SIZE])
                total = FRAME_HEADER_SIZE + payload_len
                if len(buf) < total:
                    break
                payload = buf[FRAME_HEADER_SIZE:total]
                buf = buf[total:]
                await self._handle_frame(frame_type, channel_id, payload)

    async def _handle_frame(self, frame_type: int, channel_id: int, payload: bytes):
        if frame_type == FRAME_CONNECT_OK:
            fut = self.connect_waiters.get(channel_id)
            if fut and not fut.done():
                fut.set_result(True)
            return

        if frame_type == FRAME_CONNECT_FAIL:
            fut = self.connect_waiters.get(channel_id)
            if fut and not fut.done():
                fut.set_result(False)
            return

        ch = self.channels.get(channel_id)
        if not ch:
            return

        if frame_type == FRAME_DATA:
            try:
                ch.local_writer.write(payload)
                await ch.local_writer.drain()
            except Exception:
                await self.close_channel(channel_id, notify_remote=False)
        elif frame_type == FRAME_CLOSE:
            await self.close_channel(channel_id, notify_remote=False)

    async def send_frame(self, frame_type: int, channel_id: int, payload: bytes = b""):
        if not self.connected or not self.writer:
            raise RuntimeError("tunnel not connected")
        async with self.write_lock:
            self.writer.write(make_frame(frame_type, channel_id, payload))
            await self.writer.drain()

    async def open_channel(
        self,
        target_host: str,
        target_port: int,
        local_reader: asyncio.StreamReader,
        local_writer: asyncio.StreamWriter,
    ) -> Tuple[int, bool]:
        await self.connected_event.wait()
        if not self.connected:
            return 0, False

        async with self.channel_lock:
            channel_id = self.next_channel_id
            self.next_channel_id += 1

        ch = Channel(channel_id=channel_id, local_reader=local_reader, local_writer=local_writer, connected=True)
        self.channels[channel_id] = ch

        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self.connect_waiters[channel_id] = fut
        try:
            payload = make_connect_payload(target_host, target_port)
            await self.send_frame(FRAME_CONNECT, channel_id, payload)
            ok = await asyncio.wait_for(fut, timeout=20.0)
            if not ok:
                await self.close_channel(channel_id, notify_remote=False)
                return channel_id, False
            return channel_id, True
        except Exception:
            await self.close_channel(channel_id, notify_remote=False)
            return channel_id, False
        finally:
            self.connect_waiters.pop(channel_id, None)

    async def send_data(self, channel_id: int, data: bytes):
        await self.send_frame(FRAME_DATA, channel_id, data)

    async def close_channel(self, channel_id: int, notify_remote: bool = True):
        ch = self.channels.get(channel_id)
        if not ch:
            return
        ch.connected = False
        self.channels.pop(channel_id, None)
        if notify_remote and self.connected:
            try:
                await self.send_frame(FRAME_CLOSE, channel_id)
            except Exception:
                pass
        try:
            ch.local_writer.close()
            await ch.local_writer.wait_closed()
        except Exception:
            pass

    async def _mark_disconnected(self):
        self.connected = False
        self.connected_event.clear()
        for fut in list(self.connect_waiters.values()):
            if not fut.done():
                fut.set_result(False)
        self.connect_waiters.clear()
        for ch in list(self.channels.values()):
            await self.close_channel(ch.channel_id, notify_remote=False)
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass
        self.reader = None
        self.writer = None


class RelayService:
    def __init__(self, tunnel: TunnelConnection, rules: List[ForwardRule]):
        self.tunnel = tunnel
        self.rules = rules

    async def handle_local(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        rule: ForwardRule,
    ):
        peer = writer.get_extra_info("peername")
        logger.info("Inbound %s -> %s:%s", peer, rule.target_host, rule.target_port)
        channel_id = 0
        try:
            channel_id, ok = await self.tunnel.open_channel(
                rule.target_host, rule.target_port, reader, writer
            )
            if not ok:
                return

            while True:
                data = await reader.read(32768)
                if not data:
                    break
                await self.tunnel.send_data(channel_id, data)
        except Exception:
            pass
        finally:
            if channel_id:
                await self.tunnel.close_channel(channel_id, notify_remote=True)
            else:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass

    async def run(self):
        tunnel_task = asyncio.create_task(self.tunnel.run_forever())
        servers = []
        try:
            for rule in self.rules:
                async def handler(r, w, rr=rule):
                    await self.handle_local(r, w, rr)

                srv = await asyncio.start_server(
                    handler,
                    rule.listen_host,
                    rule.listen_port,
                    reuse_address=True,
                )
                servers.append(srv)
                logger.info(
                    "Listening on %s:%s -> %s:%s",
                    rule.listen_host,
                    rule.listen_port,
                    rule.target_host,
                    rule.target_port,
                )

            await asyncio.gather(*(srv.serve_forever() for srv in servers), tunnel_task)
        finally:
            tunnel_task.cancel()
            for srv in servers:
                srv.close()
                await srv.wait_closed()


def parse_rules(data: dict) -> List[ForwardRule]:
    rules = []
    for item in data.get("forwards", []):
        listen = str(item.get("listen", "0.0.0.0:8080"))
        listen_host, listen_port_s = listen.rsplit(":", 1)
        rules.append(
            ForwardRule(
                listen_host=listen_host,
                listen_port=int(listen_port_s),
                target_host=str(item.get("target_host", "127.0.0.1")),
                target_port=int(item.get("target_port", 8080)),
            )
        )
    return rules


def main():
    parser = argparse.ArgumentParser(description="SMTP Tunnel Relay (Server A)")
    parser.add_argument("--config", "-c", default="client.yaml")
    parser.add_argument("--debug", "-d", action="store_true")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    cfg = load_config(args.config)
    cc = cfg.get("client", {})
    rules = parse_rules(cfg)
    if not rules:
        logger.error("No forwards configured")
        return 1

    server_host = str(cc.get("server_host", "127.0.0.1"))
    server_port = int(cc.get("server_port", 587))
    username = str(cc.get("username", ""))
    secret = str(cc.get("secret", ""))
    tls_server_name = cc.get("tls_server_name")
    ca_cert = cc.get("ca_cert")

    if not username or not secret:
        logger.error("client.username and client.secret are required")
        return 1

    tunnel = TunnelConnection(
        server_host=server_host,
        server_port=server_port,
        username=username,
        secret=secret,
        tls_server_name=tls_server_name,
        ca_cert=ca_cert,
    )
    relay = RelayService(tunnel, rules)

    try:
        asyncio.run(relay.run())
    except KeyboardInterrupt:
        logger.info("Stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

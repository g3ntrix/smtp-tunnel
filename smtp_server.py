#!/usr/bin/env python3
"""
SMTP Tunnel Server (Server B).

Flow:
SMTP greeting -> EHLO -> STARTTLS -> EHLO -> AUTH -> BINARY -> multiplexed TCP channels.
"""

import argparse
import asyncio
import logging
import os
import ssl
import struct
from dataclasses import dataclass
from typing import Dict, Optional

from common import load_config, load_users, verify_auth_token_multi_user, UserConfig


logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("smtp-tunnel-server")


FRAME_DATA = 0x01
FRAME_CONNECT = 0x02
FRAME_CONNECT_OK = 0x03
FRAME_CONNECT_FAIL = 0x04
FRAME_CLOSE = 0x05
FRAME_HEADER_SIZE = 5


def make_frame(frame_type: int, channel_id: int, payload: bytes = b"") -> bytes:
    return struct.pack(">BHH", frame_type, channel_id, len(payload)) + payload


def parse_frame_header(data: bytes):
    if len(data) < FRAME_HEADER_SIZE:
        return None
    return struct.unpack(">BHH", data[:FRAME_HEADER_SIZE])


@dataclass
class Channel:
    channel_id: int
    host: str
    port: int
    reader: Optional[asyncio.StreamReader] = None
    writer: Optional[asyncio.StreamWriter] = None
    connected: bool = False


class TunnelSession:
    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        hostname: str,
        ssl_context: ssl.SSLContext,
        users: Dict[str, UserConfig],
    ):
        self.reader = reader
        self.writer = writer
        self.hostname = hostname
        self.ssl_context = ssl_context
        self.users = users
        self.channels: Dict[int, Channel] = {}
        self.write_lock = asyncio.Lock()
        self.username: Optional[str] = None

    def _log(self, level: int, message: str):
        if self.username:
            logger.log(level, "[%s] %s", self.username, message)
        else:
            logger.log(level, message)

    async def run(self):
        peer = self.writer.get_extra_info("peername")
        self._log(logging.INFO, f"Connection from {peer}")
        try:
            ok = await self._smtp_handshake()
            if not ok:
                return
            await self._binary_mode()
        except Exception as exc:
            self._log(logging.ERROR, f"Session error: {exc}")
        finally:
            await self._cleanup()
            self._log(logging.INFO, "Session ended")

    async def _smtp_handshake(self) -> bool:
        await self._send_line(f"220 {self.hostname} ESMTP Postfix (Ubuntu)")

        line = await self._read_line()
        if not line or not line.upper().startswith(("EHLO", "HELO")):
            return False

        await self._send_line(f"250-{self.hostname}")
        await self._send_line("250-STARTTLS")
        await self._send_line("250-AUTH PLAIN LOGIN")
        await self._send_line("250 8BITMIME")

        line = await self._read_line()
        if not line or line.upper() != "STARTTLS":
            return False
        await self._send_line("220 2.0.0 Ready to start TLS")

        await self._upgrade_tls()

        line = await self._read_line()
        if not line or not line.upper().startswith(("EHLO", "HELO")):
            return False

        await self._send_line(f"250-{self.hostname}")
        await self._send_line("250-AUTH PLAIN LOGIN")
        await self._send_line("250 8BITMIME")

        line = await self._read_line()
        if not line or not line.upper().startswith("AUTH"):
            return False

        parts = line.split(" ", 2)
        if len(parts) < 3:
            await self._send_line("535 5.7.8 Authentication failed")
            return False

        token = parts[2]
        ok, username = verify_auth_token_multi_user(token, self.users)
        if not ok or not username:
            await self._send_line("535 5.7.8 Authentication failed")
            return False

        self.username = username
        await self._send_line("235 2.7.0 Authentication successful")

        line = await self._read_line()
        if line != "BINARY":
            return False
        await self._send_line("299 Binary mode activated")
        self._log(logging.INFO, "Authenticated, binary mode enabled")
        return True

    async def _upgrade_tls(self):
        transport = self.writer.transport
        protocol = self.writer._protocol  # pylint: disable=protected-access
        loop = asyncio.get_event_loop()
        new_transport = await loop.start_tls(
            transport, protocol, self.ssl_context, server_side=True
        )
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

    async def _binary_mode(self):
        buf = b""
        while True:
            chunk = await self.reader.read(65536)
            if not chunk:
                break
            buf += chunk

            while len(buf) >= FRAME_HEADER_SIZE:
                header = parse_frame_header(buf)
                if not header:
                    break
                frame_type, channel_id, payload_len = header
                total_len = FRAME_HEADER_SIZE + payload_len
                if len(buf) < total_len:
                    break
                payload = buf[FRAME_HEADER_SIZE:total_len]
                buf = buf[total_len:]
                await self._handle_frame(frame_type, channel_id, payload)

    async def _handle_frame(self, frame_type: int, channel_id: int, payload: bytes):
        if frame_type == FRAME_CONNECT:
            await self._handle_connect(channel_id, payload)
        elif frame_type == FRAME_DATA:
            await self._handle_data(channel_id, payload)
        elif frame_type == FRAME_CLOSE:
            await self._handle_close(channel_id)

    async def _handle_connect(self, channel_id: int, payload: bytes):
        try:
            host_len = payload[0]
            host = payload[1 : 1 + host_len].decode("utf-8")
            port = struct.unpack(">H", payload[1 + host_len : 3 + host_len])[0]
        except Exception:
            await self._send_frame(FRAME_CONNECT_FAIL, channel_id, b"bad connect payload")
            return

        self._log(logging.INFO, f"CONNECT ch={channel_id} -> {host}:{port}")
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=15.0)
            ch = Channel(channel_id=channel_id, host=host, port=port, reader=reader, writer=writer, connected=True)
            self.channels[channel_id] = ch
            asyncio.create_task(self._channel_reader(ch))
            await self._send_frame(FRAME_CONNECT_OK, channel_id)
        except Exception as exc:
            await self._send_frame(FRAME_CONNECT_FAIL, channel_id, str(exc).encode("utf-8")[:120])

    async def _handle_data(self, channel_id: int, payload: bytes):
        ch = self.channels.get(channel_id)
        if not ch or not ch.connected or not ch.writer:
            return
        try:
            ch.writer.write(payload)
            await ch.writer.drain()
        except Exception:
            await self._close_channel(ch)

    async def _handle_close(self, channel_id: int):
        ch = self.channels.get(channel_id)
        if ch:
            await self._close_channel(ch)

    async def _channel_reader(self, ch: Channel):
        try:
            while ch.connected and ch.reader:
                data = await ch.reader.read(32768)
                if not data:
                    break
                await self._send_frame(FRAME_DATA, ch.channel_id, data)
        except Exception:
            pass
        finally:
            if ch.connected:
                await self._send_frame(FRAME_CLOSE, ch.channel_id)
                await self._close_channel(ch)

    async def _send_frame(self, frame_type: int, channel_id: int, payload: bytes = b""):
        if self.writer.is_closing():
            return
        try:
            async with self.write_lock:
                self.writer.write(make_frame(frame_type, channel_id, payload))
                await self.writer.drain()
        except Exception:
            pass

    async def _close_channel(self, ch: Channel):
        if not ch.connected:
            return
        ch.connected = False
        if ch.writer:
            try:
                ch.writer.close()
                await ch.writer.wait_closed()
            except Exception:
                pass
        self.channels.pop(ch.channel_id, None)

    async def _cleanup(self):
        for ch in list(self.channels.values()):
            await self._close_channel(ch)
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:
            pass


class TunnelServer:
    def __init__(self, host: str, port: int, hostname: str, cert_file: str, key_file: str, users: Dict[str, UserConfig]):
        self.host = host
        self.port = port
        self.hostname = hostname
        self.users = users
        self.ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.ssl_context.load_cert_chain(cert_file, key_file)

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        session = TunnelSession(reader, writer, self.hostname, self.ssl_context, self.users)
        await session.run()

    async def start(self):
        server = await asyncio.start_server(self.handle_client, self.host, self.port)
        addr = server.sockets[0].getsockname()
        logger.info("SMTP tunnel server listening on %s:%s", addr[0], addr[1])
        logger.info("Users loaded: %d", len(self.users))
        async with server:
            await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="SMTP Tunnel Server")
    parser.add_argument("--config", "-c", default="server.yaml")
    parser.add_argument("--users", "-u", default=None)
    parser.add_argument("--debug", "-d", action="store_true")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    cfg = load_config(args.config).get("server", {})
    host = cfg.get("host", "0.0.0.0")
    port = int(cfg.get("port", 587))
    hostname = cfg.get("hostname", "mail.example.com")
    cert_file = cfg.get("cert_file", "server.crt")
    key_file = cfg.get("key_file", "server.key")
    users_file = args.users or cfg.get("users_file", "users.yaml")

    if not os.path.exists(cert_file):
        logger.error("Certificate file not found: %s", cert_file)
        return 1
    if not os.path.exists(key_file):
        logger.error("Key file not found: %s", key_file)
        return 1

    users = load_users(users_file)
    if not users:
        logger.error("No users configured in %s", users_file)
        return 1

    srv = TunnelServer(host, port, hostname, cert_file, key_file, users)
    try:
        asyncio.run(srv.start())
    except KeyboardInterrupt:
        logger.info("Server stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

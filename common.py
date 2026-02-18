#!/usr/bin/env python3
"""
Shared utilities for SMTP tunnel server/relay.
"""

import base64
import hashlib
import hmac
import time
from dataclasses import dataclass
from typing import Dict, Optional, Tuple

import yaml


AUTH_PREFIX = "smtp-tunnel-auth"


@dataclass
class UserConfig:
    username: str
    secret: str
    logging: bool = True


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def load_users(path: str) -> Dict[str, UserConfig]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}

    out: Dict[str, UserConfig] = {}
    users = data.get("users", {})
    for username, cfg in users.items():
        if isinstance(cfg, dict):
            out[username] = UserConfig(
                username=username,
                secret=str(cfg.get("secret", "")),
                logging=bool(cfg.get("logging", True)),
            )
        else:
            out[username] = UserConfig(username=username, secret=str(cfg), logging=True)
    return out


def generate_auth_token(username: str, secret: str, timestamp: Optional[int] = None) -> str:
    ts = int(timestamp or time.time())
    msg = f"{AUTH_PREFIX}:{username}:{ts}".encode("utf-8")
    mac = hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).digest()
    raw = f"{username}:{ts}:{base64.b64encode(mac).decode('ascii')}"
    return base64.b64encode(raw.encode("utf-8")).decode("ascii")


def verify_auth_token_multi_user(token: str, users: Dict[str, UserConfig], max_age: int = 300) -> Tuple[bool, Optional[str]]:
    try:
        decoded = base64.b64decode(token).decode("utf-8")
        parts = decoded.split(":")
        if len(parts) != 3:
            return False, None

        username, ts_str, _mac_b64 = parts
        ts = int(ts_str)
        if abs(int(time.time()) - ts) > max_age:
            return False, None

        user = users.get(username)
        if not user or not user.secret:
            return False, None

        expected = generate_auth_token(username, user.secret, timestamp=ts)
        if hmac.compare_digest(token, expected):
            return True, username
        return False, None
    except Exception:
        return False, None

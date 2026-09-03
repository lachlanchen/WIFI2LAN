#!/usr/bin/env python3
"""Authenticate one IPv4 client through an SRun portal without storing secrets."""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request


STANDARD_BASE64 = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
SRUN_BASE64 = b"LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA"


def _sencode(message: bytes, include_length: bool) -> list[int]:
    result = []
    for offset in range(0, len(message), 4):
        word = 0
        for shift, value in enumerate(message[offset : offset + 4]):
            word |= value << (shift * 8)
        result.append(word)
    if include_length:
        result.append(len(message))
    return result


def _lencode(words: list[int]) -> bytes:
    result = bytearray()
    for word in words:
        result.extend((word & 0xFFFFFFFF).to_bytes(4, "little"))
    return bytes(result)


def xencode(message: str, key: str) -> bytes:
    if not message:
        return b""
    values = _sencode(message.encode(), True)
    key_words = _sencode(key.encode(), False)
    key_words.extend([0] * (4 - len(key_words)))
    count = len(values) - 1
    z = values[count]
    total = 0
    rounds = 6 + 52 // (count + 1)
    while rounds:
        rounds -= 1
        total = (total + 0x9E3779B9) & 0xFFFFFFFF
        selector = (total >> 2) & 3
        for index in range(count):
            y = values[index + 1]
            mixed = (
                ((z >> 5) ^ ((y << 2) & 0xFFFFFFFF))
                + (((y >> 3) ^ ((z << 4) & 0xFFFFFFFF)) ^ (total ^ y))
                + (key_words[(index & 3) ^ selector] ^ z)
            ) & 0xFFFFFFFF
            values[index] = (values[index] + mixed) & 0xFFFFFFFF
            z = values[index]
        y = values[0]
        mixed = (
            ((z >> 5) ^ ((y << 2) & 0xFFFFFFFF))
            + (((y >> 3) ^ ((z << 4) & 0xFFFFFFFF)) ^ (total ^ y))
            + (key_words[(count & 3) ^ selector] ^ z)
        ) & 0xFFFFFFFF
        values[count] = (values[count] + mixed) & 0xFFFFFFFF
        z = values[count]
    return _lencode(values)


def srun_info(payload: dict[str, object], token: str) -> str:
    compact = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    encoded = base64.b64encode(xencode(compact, token))
    translated = encoded.translate(bytes.maketrans(STANDARD_BASE64, SRUN_BASE64))
    return "{SRBX1}" + translated.decode("ascii")


def fetch(url: str, interface: str | None) -> str:
    if interface:
        completed = subprocess.run(
            [
                "curl.exe" if os.name == "nt" else "curl",
                "--interface",
                interface,
                "--fail-with-body",
                "--silent",
                "--show-error",
                "--connect-timeout",
                "8",
                "--max-time",
                "20",
                url,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout
    with urllib.request.urlopen(url, timeout=20) as response:
        return response.read().decode("utf-8", errors="replace")


def parse_jsonp(text: str) -> dict[str, object]:
    match = re.search(r"^[^(]*\((.*)\)\s*;?\s*$", text.strip(), re.S)
    if not match:
        raise RuntimeError(f"portal returned non-JSONP data: {text[:200]}")
    return json.loads(match.group(1))


def portal_call(
    base: str,
    endpoint: str,
    params: dict[str, object],
    interface: str | None,
) -> dict[str, object]:
    stamp = int(time.time() * 1000)
    callback = f"jQuery1124_{stamp}"
    query = {"callback": callback, **params, "_": stamp}
    url = f"{base.rstrip('/')}{endpoint}?{urllib.parse.urlencode(query)}"
    return parse_jsonp(fetch(url, interface))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portal", required=True, help="Portal origin, for example http://portal-address")
    parser.add_argument("--username", required=True)
    parser.add_argument("--client-ip", required=True)
    parser.add_argument("--ac-id", default="1")
    parser.add_argument("--interface", help="Local source address or interface passed to curl")
    parser.add_argument("--password-env", help="Read the password from this environment variable")
    args = parser.parse_args()

    if args.password_env:
        password = os.environ.get(args.password_env)
        if password is None:
            raise SystemExit(f"environment variable is not set: {args.password_env}")
    else:
        password = getpass.getpass("Portal password: ")

    challenge = portal_call(
        args.portal,
        "/cgi-bin/get_challenge",
        {"username": args.username, "ip": args.client_ip},
        args.interface,
    )
    token = str(challenge.get("challenge", ""))
    if not token:
        raise SystemExit(f"challenge failed: {json.dumps(challenge, ensure_ascii=False)}")

    digest = hmac.new(token.encode(), password.encode(), hashlib.md5).hexdigest()
    info = srun_info(
        {
            "username": args.username,
            "password": password,
            "ip": args.client_ip,
            "acid": args.ac_id,
            "enc_ver": "srun_bx1",
        },
        token,
    )
    checksum_source = "".join(
        token + value
        for value in (
            args.username,
            digest,
            args.ac_id,
            args.client_ip,
            "200",
            "1",
            info,
        )
    )
    result = portal_call(
        args.portal,
        "/cgi-bin/srun_portal",
        {
            "action": "login",
            "username": args.username,
            "password": "{MD5}" + digest,
            "os": "Windows NT",
            "name": "Windows",
            "double_stack": 0,
            "chksum": hashlib.sha1(checksum_source.encode()).hexdigest(),
            "info": info,
            "ac_id": args.ac_id,
            "ip": args.client_ip,
            "n": 200,
            "type": 1,
        },
        args.interface,
    )
    # Successful portals may return a bearer-style access token. It is not
    # needed after login and should not be copied into terminal logs.
    visible_result = {key: value for key, value in result.items() if key != "access_token"}
    print(json.dumps(visible_result, ensure_ascii=False, sort_keys=True))
    if result.get("error") == "ok" or result.get("res") == "ok":
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

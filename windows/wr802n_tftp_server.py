#!/usr/bin/env python3
"""Minimal, locked-down TFTP server for TL-WR802N v1 U-Boot recovery."""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


OP_RRQ = 1
OP_DATA = 3
OP_ACK = 4
OP_ERROR = 5
OP_OACK = 6
DEFAULT_NAMES = (
    "wr802nv1_tp_recovery.bin",
    "wr841nv10_tp_recovery.bin",
)


class TransferError(RuntimeError):
    pass


def emit(event: str, **fields: object) -> None:
    record = {
        "time": datetime.now(timezone.utc).astimezone().isoformat(),
        "event": event,
        **fields,
    }
    print(json.dumps(record, ensure_ascii=True, sort_keys=True), flush=True)


def error_packet(code: int, message: str) -> bytes:
    return struct.pack("!HH", OP_ERROR, code) + message.encode("ascii") + b"\0"


def parse_rrq(packet: bytes) -> tuple[str, str, dict[str, str]]:
    if len(packet) < 4 or struct.unpack("!H", packet[:2])[0] != OP_RRQ:
        raise ValueError("not an RRQ packet")
    fields = packet[2:].split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) < 2 or (len(fields) - 2) % 2:
        raise ValueError("malformed RRQ fields")
    filename = fields[0].decode("ascii", errors="strict")
    mode = fields[1].decode("ascii", errors="strict").lower()
    options: dict[str, str] = {}
    for index in range(2, len(fields), 2):
        key = fields[index].decode("ascii", errors="strict").lower()
        value = fields[index + 1].decode("ascii", errors="strict")
        options[key] = value
    return filename, mode, options


def negotiate_options(
    requested: dict[str, str], image_size: int
) -> tuple[int, float, dict[str, str]]:
    # RFC 2347 lets a server ignore every requested extension. Fixed RFC 1350
    # 512-byte blocks are the most conservative choice for this old U-Boot.
    del requested, image_size
    return 512, 2.0, {}


def wait_for_ack(
    transfer: socket.socket,
    peer: tuple[str, int],
    block: int,
    outgoing: bytes,
    retry_seconds: float,
    retries: int,
) -> None:
    expected = block & 0xFFFF
    for attempt in range(1, retries + 1):
        transfer.sendto(outgoing, peer)
        transfer.settimeout(retry_seconds)
        deadline = time.monotonic() + retry_seconds
        while time.monotonic() < deadline:
            try:
                packet, sender = transfer.recvfrom(2048)
            except socket.timeout:
                break
            if sender != peer:
                transfer.sendto(error_packet(5, "Unknown transfer ID"), sender)
                continue
            if len(packet) < 4:
                continue
            opcode, received_block = struct.unpack("!HH", packet[:4])
            if opcode == OP_ACK and received_block == expected:
                return
            if opcode == OP_ERROR:
                message = packet[4:].rstrip(b"\0").decode("ascii", errors="replace")
                raise TransferError(f"client returned TFTP error: {message}")
        emit("retry", attempt=attempt, block=expected)
    raise TransferError(f"no ACK for block {expected} after {retries} attempts")


def transfer_image(
    bind_address: str,
    transfer_port: int,
    peer: tuple[str, int],
    image: bytes,
    options: dict[str, str],
    retries: int,
) -> int:
    block_size, retry_seconds, accepted = negotiate_options(options, len(image))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as transfer:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            transfer.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        transfer.bind((bind_address, transfer_port))
        local_port = transfer.getsockname()[1]
        emit(
            "transfer-start",
            peer=f"{peer[0]}:{peer[1]}",
            local_port=local_port,
            block_size=block_size,
            options=accepted,
        )

        if accepted:
            payload = b"".join(
                key.encode("ascii") + b"\0" + value.encode("ascii") + b"\0"
                for key, value in accepted.items()
            )
            wait_for_ack(
                transfer,
                peer,
                0,
                struct.pack("!H", OP_OACK) + payload,
                retry_seconds,
                retries,
            )

        offset = 0
        sequence = 1
        while True:
            chunk = image[offset : offset + block_size]
            block = sequence & 0xFFFF
            outgoing = struct.pack("!HH", OP_DATA, block) + chunk
            wait_for_ack(
                transfer,
                peer,
                block,
                outgoing,
                retry_seconds,
                retries,
            )
            offset += len(chunk)
            if len(chunk) < block_size:
                return offset
            sequence += 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--bind", default="192.168.0.66")
    parser.add_argument("--client", default="192.168.0.86")
    parser.add_argument("--port", type=int, default=69)
    parser.add_argument("--transfer-port", type=int, default=1069)
    parser.add_argument("--wait-seconds", type=int, default=1800)
    parser.add_argument("--retries", type=int, default=10)
    parser.add_argument("--success-marker", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    image_path = args.image.resolve(strict=True)
    image = image_path.read_bytes()
    digest = hashlib.sha256(image).hexdigest()
    expected = args.sha256.lower()
    if digest != expected:
        raise SystemExit(f"SHA-256 mismatch: expected {expected}, got {digest}")
    if len(image) != 3_932_160:
        raise SystemExit(f"unexpected factory image size: {len(image)}")
    if image[0x40:0x44] != bytes.fromhex("08020001"):
        raise SystemExit("factory image does not contain the TL-WR802N v1 HWID")
    if image[0x44:0x48] != bytes.fromhex("00000001"):
        raise SystemExit("factory image does not contain hardware revision 1")
    if args.bind == "0.0.0.0":
        raise SystemExit("refusing to bind on every interface")

    allowed = {name.lower() for name in DEFAULT_NAMES}
    deadline = time.monotonic() + args.wait_seconds
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        listener.bind((args.bind, args.port))
        listener.settimeout(1.0)
        emit(
            "ready",
            bind=f"{args.bind}:{args.port}",
            client=args.client,
            image=str(image_path),
            bytes=len(image),
            sha256=digest,
            filenames=sorted(allowed),
        )
        while time.monotonic() < deadline:
            try:
                packet, peer = listener.recvfrom(4096)
            except socket.timeout:
                continue
            if peer[0] != args.client:
                emit("ignored-client", peer=f"{peer[0]}:{peer[1]}")
                continue
            try:
                filename, mode, options = parse_rrq(packet)
            except (UnicodeError, ValueError) as error:
                listener.sendto(error_packet(4, "Illegal TFTP operation"), peer)
                emit("invalid-request", peer=f"{peer[0]}:{peer[1]}", error=str(error))
                continue
            if "/" in filename or "\\" in filename or filename.lower() not in allowed:
                listener.sendto(error_packet(1, "File not found"), peer)
                emit("rejected-filename", filename=filename)
                continue
            if mode != "octet":
                listener.sendto(error_packet(4, "Only octet mode is supported"), peer)
                emit("rejected-mode", mode=mode)
                continue

            emit(
                "request",
                peer=f"{peer[0]}:{peer[1]}",
                filename=filename,
                mode=mode,
                options=options,
            )
            try:
                sent = transfer_image(
                    args.bind,
                    args.transfer_port,
                    peer,
                    image,
                    options,
                    args.retries,
                )
            except (OSError, TransferError, ValueError) as error:
                emit("transfer-failed", error=str(error))
                continue

            emit("complete", bytes=sent, sha256=digest, filename=filename)
            if args.success_marker:
                args.success_marker.write_text(
                    json.dumps(
                        {
                            "bytes": sent,
                            "client": peer[0],
                            "filename": filename,
                            "sha256": digest,
                        },
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            return 0

    emit("wait-timeout", seconds=args.wait_seconds)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        emit("interrupted")
        raise SystemExit(130)

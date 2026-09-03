import importlib.util
import struct
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


SRUN = load("srun_portal_login", "windows/srun-portal-login.py")
TFTP = load("wr802n_tftp_server", "windows/wr802n_tftp_server.py")


def test_srun_encoding_reference_vector():
    payload = {
        "username": "user",
        "password": "pass",
        "ip": "192.0.2.10",
        "acid": "8",
        "enc_ver": "srun_bx1",
    }
    assert SRUN.srun_info(payload, "0123456789abcdef") == (
        "{SRBX1}YcXBoyUcWy0s+FBRM+cz3BluxcdIA76bg5c3PbXHAK1SMpRo7H3HZ0uW/"
        "9HkvYFxqWt55e3ztt+p7V+SmH+wzIxgT8woPA4xpH+SmzkubmEE4YPix4cq64MrwL4="
    )


def test_srun_jsonp_parser_rejects_plain_json():
    assert SRUN.parse_jsonp('callback({"error":"ok"})') == {"error": "ok"}
    with pytest.raises(RuntimeError):
        SRUN.parse_jsonp('{"error":"ok"}')


def test_tftp_rrq_parser_and_conservative_negotiation():
    packet = (
        struct.pack("!H", TFTP.OP_RRQ)
        + b"wr802nv1_tp_recovery.bin\0octet\0blksize\0"
        + b"1468\0"
    )
    filename, mode, options = TFTP.parse_rrq(packet)
    assert filename == "wr802nv1_tp_recovery.bin"
    assert mode == "octet"
    assert options == {"blksize": "1468"}
    assert TFTP.negotiate_options(options, 3_932_160) == (512, 2.0, {})


def test_tftp_rejects_non_rrq_packet():
    with pytest.raises(ValueError):
        TFTP.parse_rrq(struct.pack("!H", TFTP.OP_ACK) + b"\0\1")

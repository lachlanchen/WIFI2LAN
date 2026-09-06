#!/usr/bin/env python3
"""Opt-in, bounded IPv4 NetworkManager failover test; never drop the link."""

import argparse
import ipaddress
import json
import os
import re
import signal
import socket
import subprocess
import time


TABLE = "wifi2lan_probe_test"
UNIT = "wifi2lan-probe-cleanup"
PROBE = "connectivity-check.ubuntu.com"


def run(*args, check=True, timeout=12, **kwargs):
    return subprocess.run(args, check=check, text=True, capture_output=True,
                          timeout=timeout, env={**os.environ, "LC_ALL": "C"},
                          **kwargs)


def preferred():
    routes = json.loads(run("ip", "-j", "-4", "route", "show", "default").stdout)
    return min(routes, key=lambda route: route.get("metric", 0))["dev"]


def connectivity(interface):
    return run("nmcli", "-g", "GENERAL.IP4-CONNECTIVITY", "device", "show",
               interface).stdout.strip().startswith("4 ")


def wait_route(interface, limit=55):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        run("nmcli", "networking", "connectivity", "check", check=False, timeout=35)
        if preferred() == interface and connectivity(interface):
            print(f"preferred={interface} connectivity=full", flush=True)
            return
        time.sleep(2)
    raise RuntimeError(f"route did not recover to healthy {interface}")


def stop_test(*_):
    raise InterruptedError("test interrupted; removing probe rule")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wired", required=True)
    parser.add_argument("--wifi", required=True)
    parser.add_argument("--simulate", action="store_true",
                        help="required acknowledgement for temporary nft rule")
    args = parser.parse_args()
    if not args.simulate or os.geteuid() != 0:
        parser.error("requires root and explicit --simulate")
    for interface in (args.wired, args.wifi):
        if not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,15}", interface):
            parser.error("invalid interface name")
    if args.wired == args.wifi:
        parser.error("two different interfaces are required")
    if preferred() != args.wired or not all(map(connectivity, (args.wired, args.wifi))):
        parser.error("start with both links healthy and wired preferred")
    if run("nft", "list", "table", "inet", TABLE, check=False).returncode == 0:
        parser.error("test table already exists; inspect it instead of overwriting")
    addresses = sorted({str(ipaddress.IPv4Address(item[4][0])) for item in
                        socket.getaddrinfo(PROBE, 80, socket.AF_INET, socket.SOCK_STREAM)})
    if not addresses:
        parser.error("no probe IPv4 addresses")
    rules = (f"add table inet {TABLE}\n"
             f"add chain inet {TABLE} output {{ type filter hook output priority 0; policy accept; }}\n"
             f'add rule inet {TABLE} output oifname "{args.wired}" '
             f'ip daddr {{ {", ".join(addresses)} }} tcp dport 80 reject with tcp reset\n')
    run("nft", "--check", "-f", "-", input=rules)
    # Independent cleanup still runs if this process is killed with SIGKILL.
    run("systemd-run", f"--unit={UNIT}", "--on-active=90",
        "/usr/sbin/nft", "delete", "table", "inet", TABLE)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop_test)
    created = False
    try:
        run("nft", "-f", "-", input=rules)
        created = True
        wait_route(args.wifi)
        # The production DNS timer runs independently; allow its normal cycle.
        time.sleep(7)
        run("curl", "--noproxy", "*", "-4", "--fail", "--silent",
                     "--show-error", "--max-time", "10", "--output", "/dev/null",
                     "https://www.apple.com/library/test/success.html")
        print("fallback HTTPS=passed; LAN was not disconnected", flush=True)
    finally:
        if created:
            run("nft", "delete", "table", "inet", TABLE, check=False)
        remaining = run("nft", "list", "table", "inet", TABLE, check=False)
        if remaining.returncode != 0:
            run("systemctl", "stop", f"{UNIT}.timer", check=False)
        else:
            print("cleanup pending: independent timer remains armed", flush=True)
    wait_route(args.wired)
    print("failover and wired recovery passed; this was not a cable or reboot test")


if __name__ == "__main__":
    main()

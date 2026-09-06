#!/usr/bin/python3
"""Align two managed uplinks' resolved catch-all domains with the IPv4 route."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=4, env={**os.environ, "LC_ALL": "C"}).stdout.strip()


def route_winner(routes, interfaces, vpn_active=False):
    if vpn_active:
        return None
    usable = [r for r in routes if r.get("type", "unicast") == "unicast"
              and r.get("dev") and "linkdown" not in r.get("flags", [])]
    if not usable:
        return None
    winner = min(usable, key=lambda r: r.get("metric", 0))["dev"]
    return winner if winner in interfaces else None


def desired_domains(domains, selected):
    return [domain for domain in domains if domain != "~."] + (["~."] if selected else [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    config = json.loads(Path(args.config).read_text())
    uuids = set(config["connections"])
    if len(uuids) != 2:
        raise ValueError("configure exactly two uplink connection UUIDs")

    import gi
    gi.require_version("NM", "1.0")
    from gi.repository import NM

    client = NM.Client.new(None)
    active = client.get_active_connections()
    interfaces = {device.get_iface() for connection in active
                  if connection.get_uuid() in uuids for device in connection.get_devices()}
    vpn_active = any(c.get_vpn() or c.get_connection_type() == "wireguard" for c in active)
    routes = json.loads(run("ip", "-j", "-4", "route", "show", "default"))
    winner = None if args.release else route_winner(routes, interfaces, vpn_active)
    changed = False
    for interface in sorted(interfaces):
        # Only own the catch-all domain; leave split-DNS/search domains intact.
        current = run("resolvectl", "domain", interface).partition(":")[2].split()
        selected = interface == winner
        domains = desired_domains(current, selected)
        if current != domains:
            run("resolvectl", "domain", interface, *(domains or [""]))
            changed = True
        wanted = "yes" if selected else "no"
        if args.release or winner is None:
            wanted = "yes"  # Yield catch-all routing to NM or the active VPN.
        current_default = run("resolvectl", "default-route", interface).partition(":")[2].strip()
        if current_default != wanted:
            run("resolvectl", "default-route", interface, wanted)
            changed = True

    state_dir = Path("/run/wifi2lan-dns")
    state_dir.mkdir(mode=0o700, exist_ok=True)
    state = state_dir / "winner"
    old = state.read_text().strip() if state.exists() else None
    new = winner or "unmanaged"
    if changed or old != new:
        run("resolvectl", "flush-caches")
        temporary = state.with_suffix(".tmp")
        temporary.write_text(new + "\n")
        temporary.replace(state)
        print(f"DNS follows {new}; catch-all domains reconciled and cache cleared")


if __name__ == "__main__":
    main()

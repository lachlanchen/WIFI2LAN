import importlib.util
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "route_dns", Path(__file__).parent / "ubuntu-client/sync-route-dns.py")
DNS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DNS)


def routes(wired=100, wifi=600):
    return [{"dev": "eth0", "metric": wired}, {"dev": "wlan0", "metric": wifi}]


def test_prefer_wired_and_penalized_fallback():
    assert DNS.route_winner(routes(), {"eth0", "wlan0"}) == "eth0"
    assert DNS.route_winner(routes(wired=20100), {"eth0", "wlan0"}) == "wlan0"
    assert DNS.route_winner(routes(wifi=20600), {"eth0", "wlan0"}) == "eth0"


def test_no_route_vpn_or_unmanaged_route_does_not_steal_dns():
    assert DNS.route_winner([], {"eth0", "wlan0"}) is None
    assert DNS.route_winner(routes(), {"eth0", "wlan0"}, vpn_active=True) is None
    assert DNS.route_winner([{"dev": "tun0", "metric": 1}] + routes(),
                            {"eth0", "wlan0"}) is None


def test_linkdown_and_blackhole_are_not_healthy_candidates():
    broken = [{"dev": "eth0", "metric": 1, "flags": ["linkdown"]},
              {"type": "blackhole", "metric": 1}, {"dev": "wlan0", "metric": 600}]
    assert DNS.route_winner(broken, {"eth0", "wlan0"}) == "wlan0"


def test_preserve_split_dns_and_idempotent_root():
    assert DNS.desired_domains(["lan", "~corp.example", "~."], False) == ["lan", "~corp.example"]
    current = ["lan", "~corp.example", "~."]
    assert DNS.desired_domains(current, True) == current
    assert DNS.desired_domains([], True) == ["~."]

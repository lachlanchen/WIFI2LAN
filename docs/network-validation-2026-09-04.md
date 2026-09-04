# Router, Windows Wi-Fi, and Pi gateway validation

Date: 2026-09-04

## Result

The three paths were tested independently:

- the DD-WRT LAN gateway at `192.168.70.1` recovered after one power cycle;
- the Bookworm Pi continued serving DHCP/DNS/NAT at `192.168.2.1/24`;
- the Pi's upstream Wi-Fi retained IPv4 and IPv6 client behavior;
- Windows could reach both local gateways while Internet traffic preferred the
  lower-metric DD-WRT Ethernet route.

No upstream SSID, password, portal account, or device authorization record is
stored here.

## DD-WRT incident

Before the power cycle, the router's LAN switch still passed traffic to another
client, but `192.168.70.1` produced no ARP reply and exposed no management
service. Its stale Windows DHCP lease was not proof that the router process was
healthy. After a ten-second power cycle, ARP, ICMP, SSH, Telnet, HTTP, DHCP, and
the routed upstream path returned. The observed symptoms are consistent with a
router control-plane hang; volatile pre-reboot logs were not recoverable.

Use a bounded manual check instead of continuous polling:

```powershell
ping 192.168.70.1
tracert -d -h 3 1.1.1.1
```

If switching still works but the gateway has no ARP response, power-cycle once
before changing configuration.

## Windows USB Wi-Fi incident

Windows associated successfully, received DHCP, and then disconnected after
about ten seconds. The WLAN event log described it as a driver-initiated
disconnect. Disabling 802.11ax did not by itself cure that upstream-specific
drop, while the same adapter remained connected to a nearby DD-WRT access point
beyond the failure interval. This isolated the remaining issue to the upstream
network/access authorization rather than a general USB or driver failure.

The reusable compatibility script is `windows/stabilize-usb-wifi.ps1`. The
adapter's permanent MAC must also be present in the upstream authorization
system. Do not clone an in-use authorized MAC, because simultaneous duplicates
cause intermittent connectivity for both devices.

## Pi persistence tightening

The NetworkManager installer now additionally sets unlimited autoconnect
retries and a permanent hardware MAC while retaining disabled Wi-Fi power
saving. A stationary installation may optionally set `WIFI_BSSID` to a
known-good access point when controller-directed roaming repeatedly selects a
broken BSSID. BSSID pinning is opt-in because it trades roaming for stability.

The downstream implementation remains one NetworkManager `shared` Ethernet
profile. There is no custom boot poller or competing DHCP/NAT service.

## Local terminal stale-lease recovery

A separate Pi 5 remained reachable by IPv6 link-local at its known Ethernet
MAC but disappeared from `192.168.70.131`. Its local web service on port 8090
was healthy. The Pi's Ethernet client profile still held `192.168.1.100/24`
and a dead `192.168.1.1` default gateway from a previously attached router.
Reactivating only the NetworkManager client profile renewed DHCP and restored
`192.168.70.131:8090` without rebooting the Pi or changing the router.

The optional dual-role installer now provides two explicit, mutually exclusive
profiles and a single `pi5-ethernet-mode` command. Client mode is the safe
default; server mode is persistent when selected but refuses activation while
an upstream Ethernet gateway answers. This preserves both roles without a
background mode controller or simultaneous DHCP servers.

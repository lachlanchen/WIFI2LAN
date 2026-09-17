# Wired-first, health-aware Ubuntu client

This is a **client of two routers**, not another router, bridge or NAT server.
Keep Ethernet and Wi-Fi connected. Prefer a healthy wired default route and
fall back to Wi-Fi when the wired uplink fails, even while Ethernet carrier
and LAN access remain available.

Validated on Ubuntu 24.04, NetworkManager 1.46 and systemd-resolved. This
recipe manages IPv4 uplinks; it is not an IPv6 or per-application VPN policy.
Both routers may depend on the same campus network, so they are not fully
independent Internet providers. Neither this nor any failover scheme guarantees
Internet when both upstreams are unavailable.

## Design

- Native NetworkManager connectivity checks run every20seconds. Healthy
  wired uses metric100, healthy Wi-Fi600. NetworkManager adds20000 to an
  unhealthy route, then removes that penalty when it recovers.
- The normal NetworkManager autoconnect and DHCP clients handle link return.
  No custom service reconnects adapters, resets radios, or reboots routers.
- A small systemd oneshot reconciles **DNS only**, every5seconds. It follows
  the selected default, retains non-root search/split-DNS domains, and clears
  resolved's cache only when DNS ownership changes or is overwritten by DHCP.
  Only the two explicitly configured connection UUIDs are managed.
- A detected NetworkManager VPN/WireGuard connection or an unmanaged default
  makes the DNS helper remove its catch-all domain and yield control. Custom
  policy routing outside NetworkManager needs its own integration; do not
  deploy this helper into an unreviewed namespace/policy-routing setup.

The DNS companion matters when one router uses a VPN and the other does not.
In the September7 test, a direct-router Apple CDN answer timed out over the
Astrill path, even though the Wi-Fi link had Internet. Changing the route alone
was insufficient. Do not hide that failure by choosing an easier test URL.

## Safe installation

For an explicitly selected second router without global failover, see
[Tao-only Chrome and per-app networking](TAO-APPS.md). This keeps the current
default route and isolates selected apps on the secondary wired adapter.

When an untrusted Wi-Fi link must not take over a working Ethernet terminal,
start with the saved Wi-Fi profile in management-only mode, **before** enabling
or connecting its radio. Inspect and back up the selected profile first; these
commands are for an IPv4 DHCP profile without manual routes or DNS:

```bash
nmcli connection modify uuid "$WIFI_UUID" connection.autoconnect no ipv4.never-default yes ipv4.ignore-auto-routes yes ipv4.ignore-auto-dns yes ipv6.method disabled
nmcli radio wifi on
nmcli --wait 30 connection up uuid "$WIFI_UUID" ifname "$WIFI_IF"
ip -4 route show default
ip -6 route show default
resolvectl status
```

Leave the working Ethernet connection untouched. This Wi-Fi profile is for
router management, not Internet fallback. Do not promote it until its
authentication, DHCP, DNS, and sustained Internet checks have passed.
For observed route flapping and why a single connectivity probe is insufficient
evidence of session-safe failover, see the
[September 13 investigation](../ddwrt-dual-radio/RADIO-AND-CLIENT-STABILITY-2026-09-13.md).
The recipe below describes the earlier health-aware policy, not a guarantee
against transient probe failures or NAT-path session loss.

First inspect the topology. Keep the currently working management path:

```bash
nmcli device status
nmcli -f NAME,UUID,DEVICE connection show
ip -4 route show default
resolvectl status
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
```

Per-device checks require reverse-path filtering not to be strict (`1`).
Ubuntu's tested value was already loose (`2`); no sysctl change was needed.
Check per-interface values too. Do not blindly disable packet filtering.

Before edits, make a root-only backup of `/etc/netplan`,
`/etc/NetworkManager` and any existing `/etc/wifi2lan-client.json`. Profile
backups may contain Wi-Fi secrets and must stay outside Git.

Create `/etc/wifi2lan-client.json`, root-owned mode0600, containing exactly
the two **existing connection UUIDs**, not addresses or profile names:

```json
{"connections": ["WIRED-CONNECTION-UUID", "WIFI-CONNECTION-UUID"]}
```

Dependencies are NetworkManager, systemd-resolved, Python3, python3-gi and
gir1.2-nm-1.0. Install from this directory:

```bash
sudo install -m 644 90-wifi2lan-connectivity.conf /etc/NetworkManager/conf.d/
sudo install -D -m 755 sync-route-dns.py /usr/local/libexec/wifi2lan-sync-route-dns
sudo install -m 644 wifi2lan-dns-route.service wifi2lan-dns-route.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo nmcli general reload conf
sudo systemctl enable --now wifi2lan-dns-route.timer
```

Reload NetworkManager's **configuration**, do not restart NetworkManager.
For an untrusted wired uplink, initially use a wired metric of30000 and DNS
priority200, preserving the working Wi-Fi metric600. Even a Wi-Fi connectivity
penalty then remains preferable to the untested wire. Retain DHCP-provided DNS
on both devices so their individual connectivity checks can resolve the probe.

With variables set to the actual profile UUID and interface:

```bash
nmcli connection modify uuid "$WIRED_UUID" ipv4.never-default no ipv4.ignore-auto-dns no ipv4.route-metric 30000 ipv4.dns-priority 200
nmcli --wait 20 connection up uuid "$WIRED_UUID" ifname "$WIRED_IF"
nmcli networking connectivity check
nmcli -f GENERAL.IP4-CONNECTIVITY,IP4 device show "$WIRED_IF"
curl --noproxy '*' -4 --interface "$WIRED_IF" --connect-timeout 5 --max-time 12 https://www.apple.com/library/test/success.html
```

Only after wired Internet and fallback access pass, arm an independent rollback
to the trial metric and promote wired to100. On the validated machine the
rollback was a120second transient systemd timer. Cancel it only after real
Internet and remote SSH checks succeed. Preserve separate routes for LAN access.

```bash
nmcli connection modify uuid "$WIRED_UUID" ipv4.route-metric 100 ipv4.dns-priority 100
nmcli device reapply "$WIRED_IF"
nmcli connection modify uuid "$WIRED_UUID" connection.autoconnect yes
nmcli connection modify uuid "$WIFI_UUID" connection.autoconnect yes
```

Do not mix non-reapplicable connection properties into an IP-only reapply:
NetworkManager1.46 rejected a combined autoconnect-retries change in testing.
Do not disable Wi-Fi after wired succeeds; it is the hot standby. Keep its
saved power-saving mode disabled for an unreliable USB adapter. This recipe
does not replace its driver or put credentials in source code.

## Verification

```bash
nmcli device status
ip -4 route show default
resolvectl status
systemctl is-enabled wifi2lan-dns-route.timer NetworkManager
journalctl -u wifi2lan-dns-route.service --since '10 minutes ago'
```

Opt-in failover test, only when both links are initially healthy:

```bash
sudo python3 test-failover.py --wired "$WIRED_IF" --wifi "$WIFI_IF" --simulate
```

It rejects only wired TCP80 requests to resolved Ubuntu probe addresses in a
dedicated temporary nftables table. It verifies selection of Wi-Fi, ordinary
HTTPS after the DNS timer runs, and return to wired after cleanup. It never
flushes the firewall or disconnects either adapter. An independent90second
cleanup timer handles a killed test process. Existing test tables are refused.
This is a simulated probe failure, not an upstream outage, cable or reboot test.
If probe DNS rotates to an address not in the captured set, the test may fail
to simulate the outage; it must not widen its firewall rules automatically.

Both simulated failover and recovery passed on September7 after the DNS fix.
Interactive TCP/UU sessions can still reconnect when the external NAT address
changes. Use SSH keepalives and a supervised carrier, not an infinite retry
around arbitrary remote commands that may have side effects.

## Removal

Stop the timer, release only its DNS settings, remove the installed files, and
reload configuration. Do not restore Wi-Fi secrets from a different machine.

```bash
sudo systemctl disable --now wifi2lan-dns-route.timer
sudo systemctl stop wifi2lan-dns-route.service
sudo /usr/local/libexec/wifi2lan-sync-route-dns --config /etc/wifi2lan-client.json --release
```

Then remove only this recipe's service/timer, helper, JSON and connectivity
drop-in; run `systemctl daemon-reload` and `nmcli general reload conf`. Restore
the original profile metrics/DNS preferences from the private backup as needed.
Do not blindly apply a whole Netplan backup over later unrelated changes.

References: [NetworkManager1.46 connectivity checking](https://www.networkmanager.dev/docs/api/1.46.2/NetworkManager.conf.html#id-1.2.3.11),
[systemd-resolved DNS routing](https://www.freedesktop.org/software/systemd/man/latest/systemd-resolved.service.html).

## Troubleshooting: duplicate or colliding uplink profiles

Keep exactly the two managed uplink profiles listed in
`/etc/wifi2lan-client.json` — one per physical adapter. Extra profiles bound to
the same NIC, or a profile whose generated Netplan id collides with another
NIC's kernel name, cause default-route flapping that masquerades as an upstream
outage.

Two failure modes seen in practice on a two-router client:

- **A stray `netplan-<ifname>` connection binding the wrong adapter.** This
  host renders NetworkManager connections through Netplan
  (`renderer: NetworkManager`). If a profile's generated file in
  `/etc/netplan/` is keyed with a top-level `ethernets:` id equal to a
  *different* adapter's kernel name (for example a Wi-Fi-uplink profile keyed
  `enp0s31f6:` while it `match`es the USB adapter's MAC), Netplan can synthesize
  a stray `netplan-enp0s31f6` connection on the wrong NIC and flap the default
  route every connectivity interval. Fix it by recreating the profile so its
  Netplan id is unique (NetworkManager's default `NM-<uuid>` naming is safe),
  not the borrowed interface name. Recreate the *fallback* profile only while
  the *primary* uplink carries traffic, so the working route is never dropped.

- **A duplicate management profile racing the internet profile.** A
  never-default "management-only" profile on the same adapter as the metric-600
  fallback can win the DHCP transaction at connect time before the intended
  profile activates. Keep one profile per adapter; delete the leftover with
  `nmcli connection delete uuid <UUID>` (safe while it is inactive), then
  confirm the live default route and Internet are unchanged.

Do not constrain a fallback profile to a subnet to "protect" it; a client
adapter briefly patched into a retired address range (a stale `192.168.1.0/24`
lease from an old router, say) is a cabling artifact, not a profile bug, and
resolves once it is on the correct router.

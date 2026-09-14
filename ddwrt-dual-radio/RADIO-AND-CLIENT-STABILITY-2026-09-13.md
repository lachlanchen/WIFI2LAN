# Radio and Ubuntu Client Review, 2026-09-13

**Follow-up:** Tao was repaired through a second Ethernet adapter on September
14. A missing VAP bridge membership was confirmed as the authentication fault,
and Tao was migrated to a working 5 GHz uplink. See the
[follow-up validation](TAO-5GHZ-VALIDATION-2026-09-14.md). The observations below
describe the earlier state, not the current unresolved status.

The existing checkout at `~/Projects/wifi2lan` was fast-forward checked against
`lachlanchen/WIFI2LAN`; it was already at `8c69214` before this review.

## Observations

- The Ubuntu 7090 USB device identifies as `0bda:8176`, Realtek RTL8188CUS.
  NetworkManager reports 2.4 GHz supported and 5/6 GHz unsupported. This
  adapter cannot join a 5 GHz AP; changing a driver setting or SSID cannot
  add the missing radio capability.
- `dd-wrt-tao` was renamed to `dd-wrt-tao-2.4` at the same BSSID. The saved
  Ubuntu profile still selected the old SSID. Its SSID was updated without
  changing the password.
- `dd-wrt-twelve-5g` was observed on 2412 MHz, channel 1. Despite its name,
  that transmission is 2.4 GHz. `dd-wrt-twelve-2.4g` and `dd-wrt-tao-2.4`
  were observed on 2432 MHz, channel 5. A 2.4-only adapter cannot audit an
  additional 5 GHz transmission, so this does not prove that all 5 GHz service
  on a router is disabled.
- The two observed twelve SSIDs advertised no WPA/RSN security. Review local
  AP authentication before treating that WLAN as a trusted management network.
  An intentionally open campus uplink is different from an open local AP.
- Before intervention, NetworkManager logs repeatedly switched the default
  route from wired to WiFi and back within roughly one second. The 20-second
  single-endpoint connectivity policy has no sustained-failure hysteresis.
  The exact cause of those transient probe failures was not established.
- Later logs also recorded explicit Ethernet disconnections requested through
  GNOME Shell, then a DHCP timeout while reconnecting. These are separate from
  automatic default-route changes; not every interruption was a NIC failure.
- After the SSID correction, the client associated at strong signal but WPA
  negotiation timed out before DHCP. An explicit WPA2/CCMP trial also failed.
  Default protocol negotiation was restored. The stored password matched the
  previously supplied value, but that does not establish the router's current
  password or prove a driver fault.
- Software encryption (`rtl8192cu swenc=1`) and the alternate in-kernel
  `rtl8xxxu` driver also timed out. Both trials were rolled back: the original
  `rtl8192cu` driver and default encryption setting are active. No persistent
  module configuration was changed. A final interface-level EAPOL capture
  received zero packets during an association attempt. This is not proof of
  a bad password or of a particular router daemon failure; AP-side inspection
  is still needed.

## Protecting the Current Terminal

The active Ethernet connection was not restarted, disconnected, or reconfigured.
It retained gateway `192.168.12.1`, route metric 100, and its own DNS server.

Before enabling the WiFi radio, the existing WiFi profile was changed to
management-only mode:

```text
connection.autoconnect=no
ipv4.never-default=yes
ipv4.ignore-auto-routes=yes
ipv4.ignore-auto-dns=yes
ipv4.dns-priority=200
ipv6.method=disabled
```

There were no manually configured WiFi routes or DNS servers to retain.
WiFi's existing metric 600 and disabled power saving were preserved. Disabling
IPv6 for this trial prevents a router advertisement from adding an alternate
Internet/DNS path outside the IPv4 guard. This is a saved configuration, not
an in-memory route adjustment.

WiFi association tests could therefore not add a default route or replace DNS
for this terminal. Ordinary and Ethernet-bound HTTPS requests returned 200
using the wired local address. No default-route changes were logged during
these tests. No NetworkManager restart, router reboot, or firmware deployment
was performed.

**End state:** WiFi disconnected with autoconnect off. The radio is available
for scanning and a deliberate management-only connection, but this profile
does not currently provide automatic Internet fallback. Do not claim both
uplinks are healthy. Keep this restriction until authentication, DHCP, DNS,
and sustained Internet tests pass over WiFi.

The previous health-aware failover design remains in the repository, but a
successful short test is not sufficient evidence for zero-disruption failover.
Switching NAT paths can break existing TCP sessions even when both paths work.
Before re-enabling automatic upstream failover, require sustained failures and
recovery, independent probes, and a management-path rollback plan. Merely
raising a route metric does not prevent a connectivity penalty from changing
the preferred link.

## Source Hardening

`configure-fixed-wifi-wan.sh` now:

1. Validates the supported radio identifiers and wired interface syntax.
2. Rejects a different uplink radio while the previously managed radio is still
   in APSTA mode. Restore wired mode on that radio before changing its role.
3. Preserves unrelated virtual APs when adding/removing the managed `.1` AP.
4. Refuses to overwrite a pre-existing, unmanaged `.1` virtual AP.
5. Uses `fwifi_radio` for a bare `status` call and reports both radios' live
   `wl band` and `wl chanspec` values, plus configured `nband` and network mode.
   The mini firmware's `wl band` command can return nothing even on success;
   configured values and `wl status` provide additional evidence. Names ending
   in `5g` are not evidence of the operating band.

The changes do not automatically set a channel, change security, swap radios,
or restart wireless services. The second radio's existing band configuration
is still preserved. On a dual-band radio configured for 2.4 GHz, preserving it
does not magically create a 5 GHz AP.

The default pytest configuration previously omitted `test_ubuntu_client.py`.
It now includes that suite and the new mocked DD-WRT suite. Tests exercise
repeat mode changes, virtual-AP preservation, refusal before NVRAM writes,
read-only status, and band diagnostics including an empty mini-firmware
response. Mock tests are not router hardware or post-reboot acceptance tests.

Validation: `python -m pytest -q` passed all 25 tests; shell syntax validation
with `sh -n` and `git diff --check` also passed.

## Router Access and Next Work

The wired router identifies as Linksys E4200, DD-WRT r62374 mini. Its SSH
service rejected the stored router public key, but password authentication
with the administrator credentials supplied by the owner succeeded. The
existing pinned host key was retained. No passwords were saved in this repo.

Read-only inspection confirmed:

- `fwifi_radio=wl0`, `wl0_mode=apsta`, station interface `eth1`, upstream SSID
  `tsinghua`, and a DHCP default route on `eth1`.
- Local second radio `wl1`/`eth2` is configured with `nband=2` and network mode
  `mixed`. Live `wl status` reports channel 1, 2.4 GHz, despite the `5g` SSID.
- The WAN DHCP client and dnsmasq were running; load was low with about 39 MB
  free RAM. Its uptime placed the latest reboot before this intervention.
- No clients were listed on the second local radio during inspection. This
  does not by itself establish that restarting it cannot affect the WAN.
- No NVRAM changes, radio restarts, router reboots, or source deployments were
  performed on either router. Repository fixes are not installed router fixes.

Tao's management address `192.168.6.1` remains unreachable from this machine
because WiFi authentication does not complete. The 7050 also had no route
through a connected Tao network, so it was not usable as an alternate path.
Use another device already connected to Tao, or a separate wired management
interface, to inspect Tao's AP security and authentication service. Keep this
workstation's working Ethernet cable and default route intact. A targeted Tao
radio restart is a troubleshooting option, not a confirmed cure, and interrupts
its clients. Do not restart the working twelve router as a substitute.

Once management access is available, inspect without changing the working WAN:

```sh
sh /tmp/configure-fixed-wifi-wan.sh status
nvram get fwifi_radio
nvram get wl0_ifname
nvram get wl1_ifname
wl -i "$(nvram get wl0_ifname)" status
wl -i "$(nvram get wl1_ifname)" status
```

Check radio role, actual band/channel, VAP security, association logs, unique
physical WAN identities, DHCP, and optional Astrill state. The AP on the
uplink's radio follows the uplink channel; upstream roaming may disrupt
downstream clients. Prefer a separately configured local radio when the
client supports its band. Do not force a station channel, disable security,
clone another device's MAC, or reboot the working wired router speculatively.

Local pre-change NetworkManager and Netplan backups are in
`/var/backups/network-guidance/20260913/`, accessible only to root. They may
contain secrets and must not be committed or restored onto another machine.

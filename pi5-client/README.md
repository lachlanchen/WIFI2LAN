# Raspberry Pi 5: safe Wi-Fi-to-LAN setup

This installer targets a fresh 64-bit Raspberry Pi OS **with Desktop**, on
either Bookworm or Trixie. It creates two mutually exclusive `eth0` roles:

| Saved mode | `wlan0` | `eth0` |
| --- | --- | --- |
| `lan-client` (installation default) | Open `tsinghua` Wi-Fi; IPv4 and IPv6 client | IPv4 and IPv6 DHCP client; no sharing |
| `wifi-router` | Open `tsinghua` Wi-Fi; IPv4 and IPv6 client | `192.168.2.1/24`; IPv4 DHCP, DNS, and NAT only |

The Pi never forwards IPv6 and never advertises IPv6 on the downstream
Ethernet link. NetworkManager's `ipv4.method shared` owns the downstream DHCP,
DNS, firewall, and NAT lifecycle, so no always-on standalone DHCP daemon can
leak onto the main LAN.

Before selecting router mode, the manager rejects the cutover if the fixed
`192.168.2.0/24` downstream network overlaps the IPv4 network currently used
by `wlan0`. It also refuses router operation when NetworkManager is explicitly
configured with `firewall-backend=none`.

## Before installing

Use Raspberry Pi Imager to prepare Raspberry Pi OS with Desktop and set the
hostname, first user, password, locale, and SSH customization there. This
repository deliberately stores no account password or Wi-Fi secret. The
`tsinghua` profile is open and has no password.

For the first boot, connect `eth0` to the existing wired LAN. It remains an
ordinary DHCP client, so SSH access is safe and the Pi cannot compete with the
main router's DHCP server.

## Install in safe client mode

Copy or clone this repository on the Pi, then run:

```bash
cd ~/wifi-to-lan
sudo ./pi5-client/install-pi5-wifi-to-lan.sh
sudo pi5-network-mode status
sudo pi5-network-mode verify
```

Installation is idempotent for the three profiles it owns. It records a
pre-install backup under `/var/backups/pi5-network-mode/` and always resets its
saved role to `lan-client`. Its final fail-closed step disconnects `eth0`,
normalizes the owned dual-stack DHCP-client profile, and reconnects it when
carrier is present. This can briefly interrupt an installation performed over
Ethernet. On the next boot, `pi5-lan-client` is the preferred profile.

The installer also:

- installs and verifies the Wi-Fi management guard before enabling SSH;
- configures Desktop Autologin (`raspi-config` B4);
- enables VNC only after the UID-1000 graphical session/compositor exists and
  verifies that TCP 5900 is listening;
- retries delayed VNC setup through `pi5-network-mode-vnc.service` and writes
  `/var/lib/pi5-network-mode/vnc-enabled` after success;
- blocks inbound TCP 22 and 5900 **only on `wlan0`**, while leaving those ports
  reachable from `eth0`;
- disables and stops any standalone `dnsmasq.service` and the former
  `pi-wifi-to-lan-router-fix.service`.

The Wi-Fi management-port guard lives in its own nftables table,
`inet pi5_management_guard`; it does not flush or replace NetworkManager's
shared-mode NAT rules. An SSH systemd dependency prevents SSH from starting
without the guard, and NetworkManager/nftables hooks reassert the table after
their normal lifecycle events.

## Safe physical cutover

While still connected to the main LAN over `eth0`, arm the systemd-supervised
transition:

```bash
sudo pi5-network-mode arm
sudo journalctl -fu pi5-network-mode-arm.service
```

The command returns immediately, so the watcher survives loss of the SSH
connection. Then:

1. Unplug `eth0` from the main LAN.
2. Leave it physically unplugged for at least five seconds.
3. Connect `eth0` only to the downstream computer, switch, or router WAN port.

The shared profile is not allowed to autoconnect until the watcher has observed
the five-second carrier loss. Downstream clients then receive a
`192.168.2.x` address and use `192.168.2.1` for their gateway and DNS.

Management from the downstream side remains available at:

```text
SSH:  <user>@192.168.2.1
VNC:  192.168.2.1:5900
```

If the cutover is no longer wanted before unplugging, cancel it:

```bash
sudo pi5-network-mode cancel-arm
```

`cancel-arm` is deliberately fail-closed: even if the watcher completed just
before cancellation, it tears down sharing and enforces `lan-client` mode.
Like `lan-client`, this can interrupt a downstream management session.

There is also a deliberately awkward direct form. It still refuses to run
while `eth0` reports carrier:

```bash
sudo pi5-network-mode wifi-router --confirm-isolated
```

## Reboots and returning to the main LAN

The explicitly selected role persists in `/var/lib/pi5-network-mode/mode`.
After a reboot, saved router intent is restored in a quarantined client state;
DHCP sharing does **not** start merely because a cable has carrier. To resume
the router, unplug `eth0` for at least five seconds and reconnect it only to the
downstream device. The boot-started watcher performs the transition without an
SSH session.

Before intentionally reconnecting `eth0` to the existing main LAN, stop
sharing and clear saved router intent:

```bash
sudo pi5-network-mode lan-client
```

This immediately disables the router profile, tears down NetworkManager's
private DHCP/DNS helper and NAT, turns off IPv4 forwarding, and restores the
Ethernet DHCP-client profile. It can interrupt the current downstream SSH/VNC
session; that is expected.

## Verification and recovery

```bash
sudo pi5-network-mode status
sudo pi5-network-mode verify
sudo systemctl status pi5-network-mode-management-guard.service
sudo systemctl status pi5-network-mode-vnc.service
sudo journalctl -u pi5-network-mode.service \
  -u pi5-network-mode-arm.service \
  -u pi5-network-mode-management-guard.service \
  -u pi5-network-mode-vnc.service
```

`verify` checks the saved role, NetworkManager methods, autoconnect safety,
forwarding state, the live DHCP/DNS helper and NAT rule, management firewall,
and SSH. While saved router intent is waiting after a reboot, it also verifies
that the isolation watcher is active and that the sharing profile cannot
autoconnect. This waiting state is not permission to reconnect the cable to
the main LAN.

VNC needs a real graphical session. If its marker remains pending, confirm that
Raspberry Pi OS with Desktop was installed and inspect the VNC unit journal.
The unit waits up to two minutes for a Wayland or Xorg session and retries on
failure.

Every manual transition records addresses, routes, connection summaries, and
forwarding state under `/var/backups/pi5-network-mode/`. NetworkManager
connection secrets are never exported into these reports.

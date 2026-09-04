# Raspberry Pi 4 NetworkManager migration validation

Date: 2026-09-04

## Purpose

Validate the simple persistent topology on a Raspberry Pi 4 Model B running
Debian 12 Bookworm:

```text
wlan0  upstream IPv4 DHCP and IPv6 client
eth0   downstream 192.168.2.1/24 IPv4 DHCP/DNS/NAT server
```

SSH and VNC must remain reachable through the Pi's upstream and downstream
addresses. Downstream IPv6 is intentionally disabled; the Pi itself remains an
IPv6 client on `wlan0`.

## State found before migration

The Pi had a functional but overlapping legacy configuration:

- ifupdown statically assigned `192.168.2.1/24` to `eth0`;
- a system-wide dnsmasq instance provided downstream DHCP;
- a boot-time oneshot service reconstructed routing state;
- persistent iptables rules contained duplicate masquerade entries;
- NetworkManager managed Wi-Fi but considered Ethernet unmanaged.

Debian's ifupdown plugin retains a strict unmanaged classification until
NetworkManager restarts after the legacy interface file is removed. The
installer detects that state, performs the one required restart, and refuses
to continue unless `eth0` becomes managed.

The downstream client successfully received a `192.168.2.x` address, proving
that the local link and DHCP server worked. HTTP traffic reached the upstream
captive portal, proving IPv4 forwarding and NAT also worked before migration.

## Migration command

The Ethernet cable was a direct downstream link, so connected activation was
safe:

```bash
sudo ACTIVATE_CONNECTED=1 LAN_CIDR=192.168.2.1/24 \
  ./install-pi5-wifi-to-lan.sh
```

The installer creates a timestamped backup under
`/var/backups/simple-wifi-to-lan/` before removing project-owned legacy files
and rules. It does not store or replace Wi-Fi credentials.

## Verification

```bash
sudo ./install-pi5-wifi-to-lan.sh status
```

Required results:

- `wlan0` is connected with IPv4 and IPv6 client addresses;
- `eth0` is connected to the `wifi-to-lan` profile;
- `eth0` owns `192.168.2.1/24`;
- `ipv4.method` is `shared` and `ipv6.method` is `disabled` on Ethernet;
- NetworkManager's private dnsmasq and `nm-shared-eth0` firewall table exist;
- the old repair service and global dnsmasq service are disabled;
- a downstream client receives a `192.168.2.x` DHCP lease;
- SSH and VNC remain reachable over the downstream link.

Internet access beyond a captive portal is a separate upstream authentication
condition and is not evidence of a DHCP/NAT failure.

## Observed result

Migration completed without rebooting the Pi. The first activation exposed a
Debian-specific strict-unmanaged transition; the installer was corrected to
restart NetworkManager once after removing the ifupdown ownership file and to
verify that Ethernet becomes managed before proceeding. A second run completed
successfully and remained idempotent over the already-created profile.

Verified live state:

- NetworkManager reported `eth0:ethernet:connected:wifi-to-lan`;
- the profile was autoconnecting with priority 999;
- NetworkManager's private dnsmasq listened only on `192.168.2.1` and offered
  `192.168.2.10` through `192.168.2.254`;
- the generated `nm-shared-eth0` nftables table contained forwarding and
  masquerade rules for `192.168.2.0/24`;
- IPv4 forwarding was enabled and IPv6 forwarding remained disabled;
- `wlan0` retained both its upstream IPv4 and IPv6 client addresses;
- the old repair unit was removed and the global dnsmasq service was disabled;
- after releasing the pre-migration lease, a Windows downstream client received
  `192.168.2.182`, gateway/DNS `192.168.2.1`, from the new DHCP server;
- downstream DNS resolution and HTTP forwarding reached the upstream captive
  portal;
- gateway ping showed 0% loss at 2 ms;
- SSH port 22 and VNC display `:1` on TCP port 5901 remained reachable.

The exact pre-migration files are retained in timestamped backups on the Pi.
The legacy implementation is also archived under `legacy/`, with the
device-specific Wi-Fi profile name sanitized.

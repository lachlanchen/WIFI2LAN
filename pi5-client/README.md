# Raspberry Pi 4/5: simple persistent Wi-Fi-to-LAN

This setup is intentionally small. Run one installer once; NetworkManager
then restores the router after every reboot and Ethernet link interruption.
There is no mode controller, arm watcher, cable handshake, or custom NAT
service.

```text
wlan0: upstream IPv4 DHCP client + IPv6 client
eth0:  downstream IPv4 DHCP/DNS/NAT server at 192.168.23.1/24
```

IPv6 is client-only on `wlan0`. It is disabled on downstream `eth0` and is not
forwarded.

## Install once

This path is for Raspberry Pi OS or Debian systems where NetworkManager owns
networking (Bookworm or newer). First connect the Pi to the intended upstream
Wi-Fi. While `eth0` is still available for management, run:

```bash
sudo ./pi5-client/install-pi5-wifi-to-lan.sh
```

The installer automatically uses the Wi-Fi profile active on `wlan0`. It:

- creates one persistent NetworkManager shared profile on `eth0`;
- assigns `192.168.23.1/24` to the downstream side;
- lets NetworkManager provide scoped DHCP, DNS, IPv4 forwarding, and NAT;
- keeps IPv4 and IPv6 client service on `wlan0`;
- disables Wi-Fi power saving;
- keeps the Wi-Fi hardware MAC stable and retries autoconnection indefinitely;
- disables other Ethernet profiles from autoconnecting;
- removes the former multi-service mode/guard controller;
- migrates this project's older ifupdown + global dnsmasq + iptables setup into
  the same timestamped backup before replacing it;
- disables the earliest `bridge-start`/`bridge-stop` units, which otherwise
  recreate that legacy setup during every boot and shutdown;
- leaves SSH and VNC reachable from both upstream and downstream networks.

The installer does not activate a DHCP server while `eth0` is visibly
connected to an existing LAN. After it finishes, unplug `eth0` and connect it
to the downstream device or router WAN port. The shared profile activates
automatically and keeps doing so in the future.

Do not reconnect this permanently shared Ethernet port to another LAN that
already has a DHCP server.

If `eth0` is already connected directly to the downstream computer/router and
it is safe to start DHCP on that link, activate during installation:

```bash
sudo ACTIVATE_CONNECTED=1 LAN_CIDR=192.168.2.1/24 \
  ./pi5-client/install-pi5-wifi-to-lan.sh
```

`ACTIVATE_CONNECTED=1` is deliberately explicit. Do not use it while `eth0`
is connected to an existing LAN with another DHCP server.

## Check

```bash
sudo ./pi5-client/install-pi5-wifi-to-lan.sh status
```

Expected active state:

- `wlan0` has upstream IPv4 and IPv6 addresses;
- `eth0` has `192.168.23.1/24`;
- the `wifi-to-lan` connection is active and has `ipv4.method=shared`;
- NetworkManager has a private `dnsmasq` process and an
  `nm-shared-eth0` nftables table.

The downstream router or computer should receive `192.168.23.x`, use
`192.168.23.1` as its gateway/DNS, and reach the Internet through `wlan0`.

## Different downstream subnet

Override the address only when installing:

```bash
sudo LAN_CIDR=192.168.50.1/24 ./pi5-client/install-pi5-wifi-to-lan.sh
```

No Wi-Fi name, password, or account credential is stored in this repository.

For a stationary Pi on a multi-access-point network that repeatedly steers it
to a broken access point, the installer can pin one known-good BSSID:

```bash
sudo WIFI_BSSID='<known-good-ap-bssid>' ./pi5-client/install-pi5-wifi-to-lan.sh
```

Leave `WIFI_BSSID` unset normally so NetworkManager can roam.

The historical `pi5-client` directory name remains for compatibility; this
NetworkManager implementation is also validated on Raspberry Pi 4.

## Optional dual client/server role

A Pi that is sometimes an ordinary client on an existing router LAN and
sometimes a Wi-Fi-to-LAN server needs two mutually exclusive profiles. Install
the lightweight selector once:

```bash
sudo ./pi5-client/install-dual-role.sh
```

Client mode is the safe installation default. It requests DHCP from the
existing LAN and renews stale leases:

```bash
sudo pi5-ethernet-mode client
```

After moving the Ethernet cable away from the existing LAN and into the
downstream device, enable the persistent server role:

```bash
sudo pi5-ethernet-mode server
```

Server mode refuses to start if the current upstream Ethernet gateway still
answers. The selected role persists because the command changes which of the
two NetworkManager profiles may autoconnect. There is no watcher, polling
daemon, or automatic guess based on a transient cable state.

## Return Ethernet to a normal LAN client

To remove the sharing role while preserving the active upstream Wi-Fi profile:

```bash
sudo ./pi5-client/reset-to-standard-network.sh
```

The reset first snapshots NetworkManager state under
`/var/backups/simple-wifi-to-lan-reset/`, removes the shared Ethernet profile
and any legacy mode-controller remnants, then activates an ordinary automatic
IPv4/IPv6 Ethernet profile. SSH and VNC configuration are left unchanged.

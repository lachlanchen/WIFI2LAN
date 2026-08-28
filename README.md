# Raspberry Pi Wi-Fi-to-LAN networking

Reproducible, reversible networking scripts for two Raspberry Pis with distinct
roles:

```text
Internet / campus Wi-Fi
          |
       wlan0
   Raspberry Pi 4B
  192.168.13.1/24
          |
        eth0
          |
     router WAN
```

The Pi 4B is the active Wi-Fi-to-Ethernet gateway. It provides DHCP, DNS,
IPv4 forwarding, NAT, and a downstream gateway at `192.168.13.1`.

The Pi 5 is currently a normal client on the main LAN. Its former
`192.168.2.1` router configuration is preserved and can be restored explicitly;
the two Pi 5 modes are never active together.

## Components

- [`pi4-router/pi4-wifi-to-lan-router.sh`](pi4-router/pi4-wifi-to-lan-router.sh)
  installs, verifies, and rolls back the Pi 4B router configuration.
- [`pi4-router/README.md`](pi4-router/README.md) documents safe activation and
  downstream validation.
- [`pi5-client/pi5-network-mode.sh`](pi5-client/pi5-network-mode.sh) switches
  the Pi 5 between its safe LAN-client state and its preserved router state.
- [`pi5-client/README.md`](pi5-client/README.md) documents the Pi 5 recovery
  path and mode commands.

## Current verified deployment

| Device | Role | Management address | Upstream |
| --- | --- | --- | --- |
| Raspberry Pi 4B | Wi-Fi-to-LAN router | `192.168.13.1` | `wlan0` |
| Raspberry Pi 5 | Main-LAN client | DHCP-assigned | `eth0` |

The Pi 4B deployment has been verified with an actual downstream router lease
and bidirectional NAT traffic, not only router-side configuration checks. SSH
and VNC remain available at `192.168.13.1` from its downstream network.

## Safety model

These scripts modify interface addresses, DHCP service state, forwarding,
firewall rules, and default routes. Read the component README before running a
mode change.

- The Pi 4B `arm` action waits for Ethernet carrier loss before enabling its
  DHCP server, avoiding a competing DHCP server on an existing LAN.
- Every installation or Pi 5 mode change creates a timestamped backup under
  `/var/backups`.
- The Pi 4B installer includes an explicit `rollback` action.
- The Pi 5 script requires an explicit mode name and retains the original
  router-side interface configuration.
- Wi-Fi credentials are managed by the operating system and are intentionally
  absent from this repository.

The defaults are tailored to the deployed machines: Raspberry Pi OS Buster on
the Pi 4B and Debian Bookworm on the Pi 5. Review interface names, service
names, and subnets before adapting them to other systems.

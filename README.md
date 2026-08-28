[English](README.md) · [العربية](i18n/README.ar.md) · [Español](i18n/README.es.md) · [Français](i18n/README.fr.md) · [日本語](i18n/README.ja.md) · [한국어](i18n/README.ko.md) · [Tiếng Việt](i18n/README.vi.md) · [中文 (简体)](i18n/README.zh-Hans.md) · [中文（繁體）](i18n/README.zh-Hant.md) · [Deutsch](i18n/README.de.md) · [Русский](i18n/README.ru.md)

[![WIFI2LAN banner](docs/assets/banner.svg)](docs/assets/banner.svg)

# WIFI2LAN

**A resilient Wi-Fi-to-Ethernet gateway for headless Raspberry Pis.**

[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-4B%20%7C%205-C51A4A?style=flat-square&logo=raspberrypi)](https://www.raspberrypi.com/)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=111827)](https://kernel.org/)
[![Sponsor](https://img.shields.io/badge/Sponsor-lachlanchen-EA4AAA?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/lachlanchen)

WIFI2LAN turns a Raspberry Pi's Wi-Fi connection into a managed Ethernet
uplink. It provides reproducible, reversible scripts for two real deployment
roles: a Pi 4B gateway at `192.168.13.1`, and a Pi 5 that can safely switch
between a normal LAN client and its preserved router configuration.

```text
Internet / campus Wi-Fi
          │
        wlan0
   ┌───────────────┐
   │ Raspberry Pi  │  DHCP · DNS · NAT · forwarding
   │ 192.168.13.1  │
   └───────┬───────┘
         eth0
          │
     router WAN / Ethernet client
```

## Why it is dependable

- **Safe cutover:** the Pi 4B `arm` action waits for Ethernet carrier loss
  before starting DHCP, so it cannot accidentally compete with the existing
  router while still plugged into the main LAN.
- **Real rollback:** installation and mode changes create timestamped backups
  under `/var/backups`; the Pi 4B includes a dedicated `rollback` action.
- **Persistent routing:** IPv4 forwarding, NAT, DNS/DHCP, Wi-Fi power settings,
  and boot-time service state are installed together and can be reasserted.
- **Headless recovery:** SSH and VNC remain usable from the downstream network.
- **No stored credentials:** Wi-Fi secrets remain in the operating system and
  are never embedded in this repository.
- **Evidence-based verification:** the deployed Pi 4B was validated using a
  real downstream DHCP lease and bidirectional NAT counters.

## Components

| Component | Purpose | Target |
| --- | --- | --- |
| [`pi4-router/`](pi4-router/) | Install, verify, persist, and roll back the active Wi-Fi-to-LAN gateway | Raspberry Pi 4B, Raspberry Pi OS Buster |
| [`pi5-client/`](pi5-client/) | Switch safely between LAN-client mode and the preserved `192.168.2.1` router mode | Raspberry Pi 5, Debian Bookworm |

## Pi 4B quick start

Read [`pi4-router/README.md`](pi4-router/README.md) before activation. With the
script copied to `/home/pi/wifi-to-lan/`, validate it first:

```bash
sudo ./pi4-router/pi4-wifi-to-lan-router.sh preflight
```

Arm the safe transition in a detached `tmux` session, then unplug the Ethernet
cable from the existing LAN:

```bash
sudo tmux new-session -d -s pi4-router \
  '/home/pi/wifi-to-lan/pi4-wifi-to-lan-router.sh arm'
```

After connecting the Pi to the downstream router WAN port, clients receive a
`192.168.13.x` lease and use `192.168.13.1` as their gateway.

## Pi 5 modes

The Pi 5 mode switch deliberately keeps client and router roles mutually
exclusive:

```bash
sudo ./pi5-client/pi5-network-mode.sh status
sudo ./pi5-client/pi5-network-mode.sh lan-client
sudo ./pi5-client/pi5-network-mode.sh wifi-router
```

See [`pi5-client/README.md`](pi5-client/README.md) for the recovery assumptions.

## Current verified deployment

| Device | Role | Management address | Upstream |
| --- | --- | --- | --- |
| Raspberry Pi 4B | Active Wi-Fi-to-LAN router | `192.168.13.1` | `wlan0` |
| Raspberry Pi 5 | Main-LAN client | DHCP-assigned | `eth0` |

## Support

| Donate | PayPal | Stripe |
| --- | --- | --- |
| [![Donate](https://img.shields.io/badge/Donate-LazyingArt-0EA5E9?style=for-the-badge&logo=ko-fi&logoColor=white)](https://chat.lazying.art/donate) | [![PayPal](https://img.shields.io/badge/PayPal-RongzhouChen-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/RongzhouChen) | [![Stripe](https://img.shields.io/badge/Stripe-Donate-635BFF?style=for-the-badge&logo=stripe&logoColor=white)](https://buy.stripe.com/aFadR8gIaflgfQV6T4fw400) |

## Scope and license

The defaults intentionally match the deployed machines. Review interface
names, service names, upstream SSID, and subnets before adapting the scripts to
another system. Network changes can interrupt remote access; keep a recovery
path available.

Copyright © Lachlan Chen. No license has been granted yet; see the repository
history for authorship and provenance.

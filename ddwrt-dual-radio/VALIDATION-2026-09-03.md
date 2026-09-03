# Linksys E4200 fixed Wi-Fi WAN validation — 2026-09-03

## Outcome

A Linksys E4200 running DD-WRT v3.0-r62374 mega was validated as a direct
Wi-Fi-to-LAN router. The final design uses an explicit fixed mode and has no
automatic cable monitor.

The 2.4 GHz physical radio is the upstream station in Broadcom APSTA mode. Its
virtual interface remains a local 2.4 GHz access point, while the second radio
remains a local 5 GHz access point. Wired LAN clients are routed and NATed
through the station interface.

## Why automatic failover was removed

The first design selected an uplink from the physical WAN-port link state.
During DD-WRT startup, the configured WAN label, active DHCP client, default
route, and real egress interface could temporarily disagree. That made a
cable-only decision unsafe and caused avoidable service interruption.

The accepted design has two explicit, reversible modes:

- fixed Wi-Fi WAN;
- native wired WAN.

No process polls the switch or changes the active WAN at runtime. Mode changes
are performed with `set-router-mode.ps1`, backed up, committed, and followed by
one reboot.

## Persistence design

DD-WRT may rewrite its in-memory WAN identity during APSTA initialization even
when DHCP and the default route correctly use the station interface. Two small
hooks handle this without continuous work:

1. A one-time startup task runs before other custom startup lines, waits for
   APSTA, corrects the WAN identity, recreates DD-WRT's native DHCP callback,
   launches `udhcpc` on the station interface, waits a bounded time for its
   route, reconciles the optional Astrill companion, and restores client NAT.
2. A firewall hook idempotently restores the LAN masquerade rule after a
   firewall rebuild.

The Astrill sequence is `start`, `ensure`, then `start` again. This handles the
observed boot race where the first start can precede policy-table readiness,
the ensure step repairs the tables, and the second start launches the
watchdog.

## Verified after a cold mode reboot

| Check | Result |
| --- | --- |
| Router board and firmware | Linksys E4200, DD-WRT v3.0-r62374 mega |
| Radio topology | APSTA upstream plus virtual 2.4 GHz AP; independent 5 GHz AP |
| Configured WAN | Station interface `eth1` |
| Default route | Station interface `eth1` |
| LAN NAT | Present and idempotent |
| Real LAN client request | HTTP 200 through the router |
| Upstream radio | Associated |
| Local 2.4 GHz AP | Up |
| Local 5 GHz AP | Up |
| Astrill companion | Healthy |
| Astrill WAN identity | `eth1` |
| Astrill watchdog | Running |
| Astrill policy health | Ready, zero unresolved domains |
| VPN state at handoff | Down |
| Remaining NVRAM | More than 2 KiB in the final check |

Allow roughly 90 seconds after reboot before judging Astrill or LAN readiness;
the old router performs policy reconciliation during that startup window.

## Windows route protection used during maintenance

The maintenance workstation was configured to prefer its direct Wi-Fi route
for Internet traffic and keep wired Ethernet secondary. This prevents a
connected router management cable from replacing a working workstation
Internet route. The final check selected Wi-Fi at metric 5 while the local
router remained reachable through Ethernet.

This workstation preference is independent of the router mode script.

## Safety and rollback

- A full NVRAM backup was copied off the router before topology changes.
- The mode script creates another timestamped backup by default.
- `set-router-mode.ps1 wired` restores the physical radio as a local AP,
  removes both fixed-Wi-Fi hooks, selects the native wired WAN, and reboots.
- NVRAM backups are device-specific and must not be restored to another
  router.

No upstream SSID, password, authorization detail, or site-specific address is
stored in this repository.

The workflow was subsequently repeated on another E4200 while its physical
WAN remained attached. That exposed and fixed a stale wired-lease boot race;
see
[`MULTI-ROUTER-VALIDATION-2026-09-03.md`](MULTI-ROUTER-VALIDATION-2026-09-03.md).

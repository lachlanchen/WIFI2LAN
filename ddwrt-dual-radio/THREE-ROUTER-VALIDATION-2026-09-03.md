# Three-router DD-WRT validation — 2026-09-03

## Scope

The reusable workflow has now been applied to three Linksys E4200 routers on
distinct LAN subnets. The third router was reached through a dedicated Windows
Ethernet adapter so the stable primary router remained the preferred Internet
route and was not modified.

No site SSID, password, account identifier, radio MAC, assigned upstream
address, router LAN address, or device-specific backup is stored here.

## First-time workflow captured

The Windows automation is split deliberately into two layers:

1. `initialize-ddwrt-router.ps1` handles a fresh router. If the workstation
   key is absent, it negotiates a small native Telnet session, downloads and
   validates a full NVRAM backup, installs only the public SSH key, starts SSH,
   and verifies key login.
2. `set-router-mode.ps1` is the normal idempotent interface. It uploads the
   router script, selects fixed Wi-Fi WAN or physical wired WAN, reboots, waits
   for the router and bounded DHCP startup, and prints live status.
3. `configure-fixed-wifi-wan.sh` contains the router-side NVRAM and one-shot
   boot logic. It stores no upstream credential because this validated uplink
   is an open network.

A fresh initialization and later mode switches use one controlled reboot.
There is no permanent Windows helper, router polling loop, or automatic cable
monitor.

## Third-router result

After a clean reboot, the third router showed:

- its physical 2.4 GHz radio associated as the upstream station;
- its copied virtual 2.4 GHz AP and independent 5 GHz AP active on the LAN;
- an upstream DHCP address and default route on the station interface;
- one native `udhcpc` process with DD-WRT's callback;
- the startup and firewall hooks present exactly once;
- LAN masquerading installed for the Wi-Fi WAN;
- repeated HTTP requests from the dedicated Windows Ethernet address
  succeeding through that router.

The status command also reports both radio identities so an operator can
register or inventory the correct physical interfaces without saving those
identities in Git.

## Reuse rules

- Assign a unique LAN subnet before connecting another router.
- Manage changes over a wired LAN port, not the radio being reconfigured.
- Confirm the board and `wl0`/`wl1` interface mapping before applying.
- Keep every NVRAM backup outside Git and tied to its source device.
- Pass `-RouterAddress` explicitly when several routers are reachable.
- Use explicit `wifi` and `wired` commands; cable insertion never changes the
  configured mode automatically.

# DD-WRT MAC-clone cleanup validation — 2026-09-03

## Situation

An additional Linksys E4200 had DD-WRT WAN MAC cloning enabled before it was
converted to fixed Wi-Fi WAN. After the conversion, DD-WRT applied the cloned
Windows USB-Ethernet identity to the physical 2.4 GHz station interface. The
station could associate, but its identity was no longer the router radio's
physical address.

The cloned address and device-specific NVRAM images were recorded outside Git.
This repository contains no real SSID, account, password, MAC, assigned WAN
address, or router LAN address.

## Safe cleanup

The sequence was:

1. Download and validate a full NVRAM backup before changing the clone.
2. Record the cloned address outside the repository.
3. Confirm the router's base, wired-WAN, 2.4 GHz, and 5 GHz physical identities.
4. Disable `mac_clone_enable` and restore explicit physical radio and wired-WAN
   values.
5. Commit once, reboot, and wait for the one-shot Wi-Fi DHCP/firewall hook.
6. Verify the runtime radio address, association, DHCP client, route, NAT,
   local APs, and real HTTP/HTTPS traffic from the wired LAN client.

The router returned with cloning disabled, the physical radio identity active,
both local Wi-Fi networks present, one native DHCP client, the default route
on the station interface, and successful Internet traffic. The workstation's
primary-router path was also tested and remained available.

## Reusable interface

`set-router-mode.ps1` now supports `-ClearMacClone` together with mandatory
`-PhysicalRadioMac` and `-PhysicalWiredWanMac` arguments. It never guesses the
vendor-specific sequence. Its normal pre-change backup runs before clone
cleanup, and the selected router-side mode script then establishes the correct
active WAN identity.

Feature-heavy firmware builds may have much less free NVRAM than mini builds.
Fixed Wi-Fi mode now refuses to commit if fewer than 2 KiB would remain. The
validated mega build retained more than that safety floor, though a smaller
firmware remains preferable when equivalent device support is available.

# Tao: 5 GHz Uplink and VAP Authentication Repair

## Verified Topology

Linksys E4200, DD-WRT r62374 mega:

```text
tsinghua 5 GHz -> wl1 / eth2 (APSTA WAN, DHCP) -> routing / Astrill
                                              -> br0 / vlan1: LAN ports
                                              -> wl0 / eth1: dd-wrt-tao-2.4
                                              -> wl1.1: dd-wrt-tao-5g
```

The additional 5 GHz local VAP was preserved; it shares the uplink's radio
and channel. The 2.4 GHz AP has its own radio. No new firmware was flashed,
MAC addresses were not cloned, and existing local passwords were retained.

## Root Cause Confirmed

Before repair, `wl0.1` existed and NAS was running for it, but it was absent
from `br0`. The same USB adapter and password that repeatedly timed out during
WPA authentication connected immediately after:

```sh
brctl addif br0 wl0.1
```

This distinguishes the confirmed bridge defect from the previous hypotheses
about driver encryption and the password. The 2.4-only USB adapter can now
use Tao's 2.4 AP while the router receives Internet through 5 GHz.

DD-WRT rewrites `lan_ifnames` back to physical interface names at boot on this
device. Configured `lan_ifnames` alone therefore does not prove live VAP bridge
membership. The fixed-WAN startup and firewall hooks now idempotently reattach
only the managed `$fwifi_radio.1` VAP to `br0`. The status action reports
`virtual_ap_bridged` from live sysfs. Tests execute the firewall hook for both
radio choices, including an already-attached/error return from `brctl`.

## Procedure Used

1. Kept the workstation's existing default route through the other router.
2. Connected a second USB Ethernet adapter to Tao's LAN, with no host default
   route, automatic DNS, or IPv6 enabled for that profile.
3. Backed up Tao's NVRAM off-router with private permissions and verified the
   transferred backup against the router's checksum. Backups include secrets
   and are not part of Git.
4. Preserved the existing SSH authorized key and added this workstation's
   public key. Verified key-only SSH using the existing pinned host key.
5. Scanned the second radio and confirmed open `tsinghua` on 5 GHz channel 36
   at about -38 dBm. The `wl scan` command is unsupported in this firmware;
   `site_survey` uses the temporary `wifi_display` selection, not an interface
   argument. The prior selection was restored after scanning.
6. Restored the old radio's local AP configuration in NVRAM, then applied the
   same reviewed fixed-WAN script to `wl1`. No intermediate reboot was made.
   A failure trap could restore the pre-transition NVRAM backup.
7. Verified radio roles, LAN membership configuration, both repair hooks, and
   more than 2 KiB remaining NVRAM before rebooting **Tao only**.
8. Verified SSH, 5 GHz association, WAN DHCP, bridge membership, Astrill
   recovery, wired-client HTTPS, and 2.4 GHz WiFi authentication after reboot.

The role transition commands were:

```sh
sh /tmp/configure-fixed-wifi-wan.sh wired wl0 vlan2
sh /tmp/configure-fixed-wifi-wan.sh wifi tsinghua wl1 vlan2
# Inspect first; only then reboot this router.
reboot
```

Do not run this sequence blindly on another router. Identify its interfaces,
upstream security, band capabilities, physical management path, and saved radio
first. The existing script supports an open upstream, not arbitrary enterprise
WiFi authentication. Changing roles interrupts Tao's clients while it reboots.

## Post-Reboot Evidence

- `fwifi_radio=wl1`, `wan_iface=eth2`, one WAN DHCP client.
- `wl -i eth2 status`: `tsinghua`, 5 GHz, primary channel 36, 40 MHz width,
  approximately -40 dBm. Do not interpret the helper's `Mode: Managed` display
  alone as the configured DD-WRT role; inspect NVRAM and bridge state as well.
- `br0`: `vlan1`, `eth1`, `wl1.1`; WAN `eth2` is not bridged to the LAN.
- Astrill's `tun0` and its split default routes returned. The companion settled
  to one watchdog and OpenVPN was running.
- Both fixed-WAN hooks include the VAP bridge repair after the actual reboot.
- The previous router was not reconfigured or rebooted. One Apple HTTPS probe
  through it timed out, while later independent wired HTTPS checks succeeded;
  no host default route or DNS takeover occurred.

For the separate browser and per-app route, see
[Tao-only apps](../ubuntu-client/TAO-APPS.md).

DD-WRT implementation reference for the scan interface selection:
[site_survey_broadcom.c](https://github.com/mirror/dd-wrt/blob/master/src/router/services/tools/site_survey_broadcom.c).

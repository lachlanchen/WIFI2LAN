# Tao WAN Role Drift and Recovery

## Observed Failure

The configured uplink marker still selected `wl1` (5 GHz), but the actual
radio settings no longer matched the September 14 deployment:

- `wl0` / `eth1` was APSTA with the upstream SSID but local WPA settings.
- `wl1` / `eth2` was an AP with the local SSID instead of the upstream.
- WAN interface keys selected `eth2`, while the live DHCP client used `eth1`.
- WAN address and gateway were zero, with no external default route.
- The secured `wl1.1` local VAP retained its correct configuration.

This configuration mismatch explains the absence of an upstream DHCP lease.
The actor or operation that changed the radio settings was not established.
Do not attribute it to Astrill, the web UI, or a hardware failure without
additional evidence.

## Safe Recovery

The workstation kept its other wired router as the preferred Internet path.
Tao was managed through a separate Ethernet adapter. A full NVRAM backup was
downloaded into private local storage and checksum-compared before changes.
It contains credentials and must never be added to Git.

After reviewing both radios and saved local AP settings, the repair used:

```sh
sh /tmp/configure-fixed-wifi-wan-repair.sh wired wl0 vlan2
sh /tmp/configure-fixed-wifi-wan-repair.sh wifi tsinghua wl1 vlan2
```

The first operation restored the old 2.4 GHz local AP from its retained VAP
settings. The second restored the intended 5 GHz upstream. A failure trap
could restore the same router's pre-change NVRAM backup. Assertions verified
both roles, SSIDs, WAN interface, and retained local WPA settings before
rebooting **only Tao**. The other router and workstation network were not
restarted.

This sequence is incident-specific. Do not blindly use it on a fresh router
or a router with different radio roles, interface names, or upstream security.

## Reusable Script Fix

Before this fix, reapplying Wi-Fi mode while the managed parent radio had
changed back to AP could copy that altered parent's settings over the existing
secured local VAP. In this incident that could have replaced WPA settings with
disabled security.

The script now preserves a VAP when its radio, saved upstream marker,
nonempty VAP SSID, and active VAP membership establish existing management.
Fresh configuration still copies the local AP into a new VAP. A deliberate
wired-to-Wi-Fi transition still copies updated local AP settings because the
old VAP has been removed from active membership. Existing refusal to overwrite
unmanaged VAPs remains unchanged.

Read-only `status` now reports saved uplink radio/SSID and
`radio_role_consistent=yes|no`. This is a configuration consistency check,
not an Internet-health guarantee. Check association, interface DHCP lease,
gateway, DNS and HTTPS independently. No loop silently resets future user
configuration changes.

## Acceptance

- After reboot, `wl0` was the local AP and `wl1` the APSTA uplink.
- The station associated on 5 GHz primary channel 36 at about -41 dBm.
- `eth2` received a nonzero upstream DHCP address and default gateway.
- `br0` contained `eth1`, `vlan1`, and `wl1.1`; WAN `eth2` stayed outside LAN.
- Exactly one WAN DHCP client used `eth2`.
- Tao-isolated client HTTPS worked before the VPN startup completed.
- Astrill bootstrapped from its saved configuration, synchronized the clock,
  and started OpenVPN. One endpoint timed out; the vendor's own retry moved
  to the next server. A later log reported initialization complete, status 3,
  and the split default routes through `tun0`.
- Client tests reached Google (204), Apple (200), and Baidu (200). A later
  Google probe timed out while companion policy tables were incomplete.
  Running the existing `alctl ensure` reconciled the policy successfully;
  it did not require a new VPN account or configuration reset.
- Final companion status was `health=healthy`, `vpn_state=up`,
  `astrill_status=3`, `policy_health=ready`, watchdog running, all three
  routing tables ready, and no reconciliation error. Three consecutive
  isolated-client Google probes returned 204 afterward. This is a bounded
  acceptance check, not a guarantee against future upstream/server outages.
- All 52 repository tests passed, including both radio variants of the VAP
  preservation regression and a normal wired-to-Wi-Fi reconfiguration test.

The brief loss of Tao during its reboot does not imply loss of the other
router. The Ubuntu default remained its original preferred wired connection.

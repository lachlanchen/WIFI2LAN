# Multi-router DD-WRT validation — 2026-09-03

## Scope

The fixed Wi-Fi-WAN workflow was repeated on another Linksys E4200 running a
current DD-WRT v3 build. The router remained connected to an upstream device
through its physical WAN port while its LAN was managed through a separate
wired adapter.

No site SSID, credential, account identifier, radio MAC, public address, or
device-specific NVRAM image is stored in this repository.

## Safety sequence

1. Confirm the management route and router identity before any change.
2. Read both radio identities and verify which DD-WRT interface belongs to
   each band.
3. Create a full device-specific NVRAM backup and copy it off the router.
4. Transfer `configure-fixed-wifi-wan.sh` and compare its checksum.
5. Apply fixed Wi-Fi mode, reboot, and inspect the live association, address,
   route, DHCP process, bridge members, and NAT table.
6. Test a real request from a LAN client through the selected Wi-Fi WAN.

The NVRAM backup is intentionally kept outside Git. Backups must never be
restored to a different router, even when the model and firmware match.

## Failure reproduced

The first APSTA boot associated successfully, but DD-WRT carried the previous
physical-WAN DHCP address onto the station interface. The interface name and
default route looked partly converted, yet the address still belonged to the
old wired subnet and could not reach the Wi-Fi gateway.

Restarting the generic `wan` service was not sufficient on this boot. It
removed the stale route but did not create the DHCP callback or launch the
client on the radio.

A read-only comparison with an already-working E4200 exposed the missing
native mechanism:

```text
/tmp/dhcpc -> /sbin/rc
udhcpc -i <station-interface> -p /var/run/udhcpc.pid -s /tmp/dhcpc
```

The router also had a pre-existing custom startup bootstrap. Starting the
Wi-Fi repair in the background allowed that bootstrap to run concurrently and
tear down the newly acquired lease during its first minute.

## Implemented correction

Fixed Wi-Fi mode now prepends one bounded startup task before existing custom
startup lines. After APSTA has initialized, it:

1. reasserts the station interface as WAN;
2. recreates `/tmp/dhcpc` as DD-WRT's native callback;
3. stops any stale DHCP client;
4. removes the stale station address and default route;
5. launches `udhcpc` on the station interface;
6. waits up to 30 seconds for the station default route;
7. rebuilds the firewall and idempotent LAN masquerade rule;
8. reconciles the optional companion only after networking is ready.

The task then exits. It does not watch cable state, poll the router, or switch
uplinks automatically. DD-WRT's normal DHCP client remains running to renew
the lease.

## Verified outcome

After a clean reboot:

- the physical 2.4 GHz radio was associated as the upstream station;
- the virtual 2.4 GHz local AP was up;
- the independent 5 GHz local AP was up;
- wired LAN management remained available;
- the station received an address from the Wi-Fi upstream rather than the
  attached physical-WAN device;
- the default route used the station interface;
- `udhcpc` used DD-WRT's native callback;
- SNAT and masquerade counters advanced for the LAN subnet;
- startup and firewall hooks each appeared exactly once;
- repeated client HTTP probes succeeded after the upstream authorization
  delay;
- more than 27 KiB of NVRAM remained free.

The same management public key used by the existing E4200 workflow was added
to this router so `set-router-mode.ps1` can perform later backup, switching,
reboot, and validation in one invocation. The private key and all credentials
remain outside the repository.

## Reuse

For each additional compatible router, confirm its interface names and use a
unique LAN subnet. From Windows:

```powershell
.\set-router-mode.ps1 wifi `
  -RouterAddress '<router-lan-ip>' `
  -UpstreamSsid '<open-upstream-ssid>'
```

Return explicitly to physical WAN with:

```powershell
.\set-router-mode.ps1 wired -RouterAddress '<router-lan-ip>'
```

Fixed modes are intentional. Plugging in or removing a WAN cable never causes
an automatic runtime mode change.

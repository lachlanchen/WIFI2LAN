# DD-WRT fixed Wi-Fi-to-LAN mode

This is the deliberately simple arrangement for a dual-radio Broadcom
DD-WRT router:

```text
upstream Wi-Fi -> 2.4 GHz station -> DD-WRT NAT -> LAN ports
                         +---------> 2.4 GHz virtual local AP
second radio ----------------------> local AP (configure/verify 5 GHz)
```

There is no cable monitor, polling daemon, or automatic failover. Choose one
mode explicitly:

- `wifi`: use an open Wi-Fi network as WAN while keeping LAN and both local
  Wi-Fi networks.
- `wired`: restore the ordinary physical wired-WAN topology.

The second radio's existing band is preserved, not forced to 5 GHz. Verify its
actual frequency; an SSID containing `5g` is only a name. A 2.4-only client
adapter cannot connect to a 5 GHz AP. See the
[September 13 radio/client review](RADIO-AND-CLIENT-STABILITY-2026-09-13.md)
for the Ubuntu terminal protection and source-hardening tests.

The radio roles can also be reversed: **5 GHz uplink with a separate 2.4 GHz
local AP and wired LAN**. See the
[Tao 5 GHz validation and authentication repair](TAO-5GHZ-VALIDATION-2026-09-14.md)
before attempting a transition. The script's default remains `wl0`; the
verified Tao configuration explicitly uses `wl1`.

The optional Astrill companion is started and reconciled once after a Wi-Fi
mode boot. VPN connection state remains controlled by Astrill itself.

## Requirements

- DD-WRT on a Broadcom router with two radios.
- SSH key access to the router.
- A wired LAN management connection while changing modes.
- An open upstream Wi-Fi network compatible with DD-WRT APSTA mode.
- Authorization for the uplink radio's MAC when the upstream requires it.

Do not reuse interface names blindly. Confirm them first:

```sh
nvram get DD_BOARD
nvram get wl0_ifname
nvram get wl1_ifname
nvram get wan_ifname
```

The defaults are `wl0` for the uplink radio and `vlan2` for physical WAN.

A bare router-side `status` command uses the saved `fwifi_radio`. Explicit
radio arguments still take precedence. To change the uplink radio after a
Wi-Fi-mode setup, first restore wired mode on the current radio using a wired
management connection. The script refuses to leave the old radio in station
mode or overwrite a pre-existing unmanaged `.1` virtual AP. Unrelated virtual
APs are retained.

## Windows commands

From this directory:

```powershell
# First use on a fresh DD-WRT router that has Telnet but no SSH key yet.
# The password is requested securely and is not stored in the command line.
.\initialize-ddwrt-router.ps1 wifi `
  -RouterAddress '<router-lan-ip>' `
  -UpstreamSsid '<upstream-name>'

# First Wi-Fi-mode setup; quote the actual upstream name locally.
.\set-router-mode.ps1 wifi -UpstreamSsid '<upstream-name>'

# Target another router without changing the script.
.\set-router-mode.ps1 wifi `
  -RouterAddress '<router-lan-ip>' `
  -UpstreamSsid '<upstream-name>'

# Later returns to Wi-Fi mode can omit the name stored in router NVRAM.
.\set-router-mode.ps1 wifi

# Return to the original physical WAN.
.\set-router-mode.ps1 wired

# Read-only status.
.\set-router-mode.ps1 status
```

`initialize-ddwrt-router.ps1` is the first-time wrapper. It checks the router
identity through its LAN address, uses a minimal built-in Telnet client only
when SSH key login is unavailable, saves a device-specific NVRAM backup,
installs the existing workstation public key, starts and verifies SSH, and
hands off to `set-router-mode.ps1`. A fresh initialization performs one
controlled reboot to apply and verify the selected WAN mode.

Run the initializer only from a directly connected, trusted LAN. Telnet sends
the router password without transport encryption. The script holds the
password as a PowerShell `SecureString`; it does not save it or put it in the
process command line. It never copies a private key onto the router.

If DD-WRT's MAC-clone option was previously enabled, preserve its old value
outside Git and explicitly supply the router's physical identities while
disabling it:

```powershell
.\set-router-mode.ps1 wifi `
  -RouterAddress '<router-lan-ip>' `
  -UpstreamSsid '<upstream-name>' `
  -ClearMacClone `
  -PhysicalRadioMac '<radio-mac>' `
  -PhysicalWiredWanMac '<wired-wan-mac>'
```

The physical addresses are mandatory with `-ClearMacClone`; the script never
guesses a vendor-specific MAC sequence. The pre-change backup is made before
the clone values are altered.

Every mode change creates and downloads a timestamped full NVRAM backup before
committing, then reboots. By default the command waits for the router to go
offline and return, allows the bounded Wi-Fi/DHCP startup to finish, uploads
the read-only status helper again, and prints the verified state. This makes a
normal mode change one command from backup through post-reboot validation.

Use `-NoBackup`, `-NoReboot`, or `-NoWait` only for controlled diagnosis. The
wait periods can be adjusted for unusually slow hardware:

```powershell
.\set-router-mode.ps1 wifi `
  -RouterAddress '<router-lan-ip>' `
  -UpstreamSsid '<upstream-name>' `
  -WaitTimeoutSeconds 240 `
  -PostBootDelaySeconds 90
```

The script copies the local 2.4 GHz AP configuration inside the router when
changing roles. No Wi-Fi password or private upstream name is stored in this
repository.

Give every managed router a unique LAN subnet before connecting several of
them to one workstation. Always pass `-RouterAddress` explicitly when the
target is not the default router, and never restore one device's NVRAM backup
onto another device.

## Router-only commands

Copy `configure-fixed-wifi-wan.sh` to `/tmp`, then run:

```sh
sh /tmp/configure-fixed-wifi-wan.sh wifi '<upstream-name>' wl0 vlan2
reboot

sh /tmp/configure-fixed-wifi-wan.sh wired wl0 vlan2
reboot
```

The Wi-Fi mode stores two small one-shot hooks:

- a startup hook runs before other custom startup lines, corrects DD-WRT's WAN
  identity after APSTA initializes, recreates DD-WRT's DHCP callback, discards
  any stale wired-WAN lease, launches `udhcpc` on the station interface, waits
  a bounded time for its default route, and then reconciles the optional
  Astrill companion;
- a firewall hook restores LAN masquerading after firewall changes.

The startup wait is bounded and exits. No custom monitor or polling daemon is
installed; the only long-running DHCP process is DD-WRT's normal `udhcpc`.
Both hooks are removed by `wired` mode.

The hooks also reattach the managed virtual AP to `br0`. On the validated
firmware, omitting this bridge membership prevented WPA authentication even
though the SSID and authentication daemon were present.

Wi-Fi mode refuses to commit if it would leave less than 2 KiB of NVRAM free.
This protects feature-heavy firmware builds from a truncated NVRAM commit.

The physical WAN cable may remain connected while fixed Wi-Fi mode is active;
the configured WAN and default route use the radio. Run explicit `wired` mode
to use that cable again.

## Verification

Wait at least 90 seconds after a Wi-Fi-mode reboot, then check:

```sh
sh /tmp/configure-fixed-wifi-wan.sh status wl0 vlan2
wl -i "$(nvram get wl0_ifname)" status
brctl show
ip route
iptables -t nat -L POSTROUTING -n -v
```

Expected Wi-Fi-mode state:

- physical uplink radio is associated in `apsta` mode;
- the virtual AP and second radio are members of `br0`;
- the default route uses the uplink radio interface;
- POSTROUTING contains NAT for the LAN subnet through that interface.

If the optional companion is installed:

```sh
/tmp/astrill-lazy/alctl status --json
```

Healthy disconnected state reports the Wi-Fi WAN interface, `watchdog: true`,
`policy_health: ready`, and `vpn_state: down`. Connecting a VPN is then the
same operation as with a wired WAN.

## Recovery

Use explicit wired mode first:

```powershell
.\set-router-mode.ps1 wired
```

For a complete recovery, upload a backup created before the mode change and
run on the router:

```sh
nvram restore /tmp/backup.bin
reboot
```

Never restore one router's NVRAM backup onto another router.

See [`MULTI-ROUTER-VALIDATION-2026-09-03.md`](MULTI-ROUTER-VALIDATION-2026-09-03.md)
for the stale-wired-lease failure mode found on a second E4200 and the exact
reason for the current boot ordering. The independent third-router repeat and
the fresh-router wrapper are recorded in
[`THREE-ROUTER-VALIDATION-2026-09-03.md`](THREE-ROUTER-VALIDATION-2026-09-03.md).
The clone-to-physical-MAC recovery and NVRAM safety floor are documented in
[`MAC-CLONE-CLEANUP-VALIDATION-2026-09-03.md`](MAC-CLONE-CLEANUP-VALIDATION-2026-09-03.md).

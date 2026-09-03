# DD-WRT fixed Wi-Fi-to-LAN mode

This is the deliberately simple arrangement for a dual-radio Broadcom
DD-WRT router:

```text
upstream Wi-Fi -> 2.4 GHz station -> DD-WRT NAT -> LAN ports
                         +---------> 2.4 GHz virtual local AP
second radio ----------------------> 5 GHz local AP
```

There is no cable monitor, polling daemon, or automatic failover. Choose one
mode explicitly:

- `wifi`: use an open Wi-Fi network as WAN while keeping LAN and both local
  Wi-Fi networks.
- `wired`: restore the ordinary physical wired-WAN topology.

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

## Windows commands

From this directory:

```powershell
# First Wi-Fi-mode setup; quote the actual upstream name locally.
.\set-router-mode.ps1 wifi -UpstreamSsid '<upstream-name>'

# Later returns to Wi-Fi mode can omit the name stored in router NVRAM.
.\set-router-mode.ps1 wifi

# Return to the original physical WAN.
.\set-router-mode.ps1 wired

# Read-only status.
.\set-router-mode.ps1 status
```

Every mode change creates and downloads a timestamped full NVRAM backup before
committing, then reboots. Use `-NoBackup` or `-NoReboot` only for controlled
diagnosis.

The script copies the local 2.4 GHz AP configuration inside the router when
changing roles. No Wi-Fi password or private upstream name is stored in this
repository.

## Router-only commands

Copy `configure-fixed-wifi-wan.sh` to `/tmp`, then run:

```sh
sh /tmp/configure-fixed-wifi-wan.sh wifi '<upstream-name>' wl0 vlan2
reboot

sh /tmp/configure-fixed-wifi-wan.sh wired wl0 vlan2
reboot
```

The Wi-Fi mode stores two small one-shot hooks:

- a startup hook corrects DD-WRT's WAN identity after APSTA initializes and
  reconciles the optional Astrill companion;
- a firewall hook restores LAN masquerading after firewall changes.

Neither hook loops or polls. Both are removed by `wired` mode.

## Verification

Wait at least 90 seconds after a Wi-Fi-mode reboot, then check:

```sh
sh /tmp/configure-fixed-wifi-wan.sh status wl0 vlan2
wl -i "$(nvram get wl0_ifname)" status
brctl show
ip route
iptables -t nat -S POSTROUTING
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

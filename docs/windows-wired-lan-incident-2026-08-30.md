# Windows wired-LAN incident — 2026-08-30

## Executive summary

The computer's wired adapter and cable were connected, but Windows had no
usable IPv4 configuration on `Ethernet`. An elevated command at 13:35:19 added
the temporary active-store address `192.168.2.2`. Windows' `netsh interface
ipv4 add address` behavior disabled DHCP on that interface. The 14:22 reboot
removed the active-store address, as intended, but did not turn DHCP back on.
The result was a connected Ethernet link with neither a DHCP lease nor a
default gateway.

The safe repair was to restore persistent automatic IPv4 addressing and DNS
with [`windows/repair-wired-dhcp.ps1`](../windows/repair-wired-dhcp.ps1). At
15:16 the adapter held the DHCP lease `192.168.1.166/24`; its default gateway,
DNS server, and DHCP server were all `192.168.1.1`. Ethernet was the preferred
Internet route, and gateway, Internet, and DNS checks passed.

This evidence does **not** indicate a cable, NIC, switch-port, or router fault.

## Evidence and timeline

| Local time (2026-08-30) | Evidence | Interpretation |
| --- | --- | --- |
| 13:35:19.306 | The `Windows PowerShell` log's Event ID 400, record 144880, captured an elevated command that added `192.168.2.2/24` to the active store. | The temporary static-address operation changed the IPv4 interface from DHCP to manual addressing. |
| 13:35:21 | Network Profile events recorded the wired `lazying.art` profile disconnecting and `Ethernet` becoming an Unidentified/Public network. | Loss of the normal IPv4 configuration was visible immediately after the command. |
| 14:20:52-14:22:18 | Windows shut down at 14:20:52 and booted at 14:22:10. The physical link returned at 14:22:16.871 at 1 Gbps, but the profile was Unidentified by 14:22:18. | Reboot removed active-store `192.168.2.2`, while DHCP remained disabled; the cable and link were working. |
| Before repair | `Ethernet` was physically `Up`/`Connected` at 1 Gbps, but DHCP was disabled. Its only address was APIPA `169.254.84.87/16`, with no gateway or DNS server. | Layer 1/link was healthy; missing IPv4 configuration caused the outage. |
| Repair | The recovery script persistently selected DHCP for both IPv4 addressing and DNS, then waited for a preferred DHCP lease and an alive default route. | Normal LAN-client configuration was restored without guessing a static address. |
| 15:16 | DHCP lease `192.168.1.166/24`; gateway, DNS, and DHCP server `192.168.1.1`; Ethernet selected for Internet traffic; gateway, Internet, and DNS checks passed. | Wired connectivity was restored and independently verified. |

Only the command's network effect and Windows event identifiers are recorded
here. The encoded command body, private session history, and credentials are
intentionally excluded.

## Pre-repair state

- `Ethernet` reported an `Up`/`Connected` physical link.
- IPv4 DHCP was disabled.
- The reboot had removed the temporary `192.168.2.2` active-store address.
- Windows self-assigned APIPA `169.254.84.87/16`; no default gateway or DNS
  server existed.
- Wi-Fi availability did not repair the independent Ethernet configuration.

This combination distinguishes the incident from a disconnected cable or
failed router port.

## Root cause

The exact failure chain was:

1. A temporary management operation used an elevated `netsh interface ipv4
   add address` command on the primary `Ethernet` interface.
2. Adding `192.168.2.2` caused Windows to disable DHCP for that interface.
3. The address was written only to the active store, so reboot removed it.
4. DHCP remained off after reboot because the interface mode had already been
   changed.
5. With no static address and no DHCP lease, Windows could not install the LAN
   default route, despite the Ethernet link remaining connected.

The reboot exposed the inconsistent lifetimes; it was not itself the original
cause.

The command also enabled the global `dhcpstaticipcoexistence` setting, but that
did not protect this interface: local `netsh` help explicitly states that
`interface ipv4 add address` disables DHCP. The active-store lifetime applied
to the address, not to the resulting DHCP-mode change.

## Safe recovery

Open **PowerShell as Administrator**, change to this repository, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\repair-wired-dhcp.ps1 `
  -InterfaceAlias "Ethernet" `
  -ResultPath "$env:TEMP\wired-dhcp-repair-result.json"
```

The script is deliberately fail-closed. It:

- requires elevation and a physically connected adapter;
- records the pre-change interface snapshot;
- sets IPv4 address and DNS acquisition to DHCP in the persistent store;
- waits up to 45 seconds for a preferred, non-APIPA DHCP lease and a live
  default route;
- records the after-state and checks route selection plus gateway and Internet
  reachability; and
- emits structured JSON, including a failure result if any required condition
  is not met.

The command is idempotent for a normal DHCP LAN, so it is safe to re-run after
a transient DHCP failure or interrupted verification. A second run should
retain automatic configuration and refresh the evidence file.

### Rollback and re-run

There is no useful rollback to the incident state: it was an unusable
combination of no address and disabled DHCP. The intended workstation state is
automatic DHCP/DNS. Re-run the recovery script to reassert that state.

If this adapter intentionally needs a static configuration in the future,
first record the approved address, prefix, gateway, and DNS values, then apply
that complete configuration through the normal Windows network settings. Do
not infer those values from this incident report. Restoring automatic mode is
always available by running the recovery script again.

## Prevention for temporary static access

Do not use `netsh interface ipv4 add address` on the primary DHCP adapter as a
harmless temporary alias: on Windows it can disable DHCP even when the address
itself is active-store-only.

Preferred approaches, in order:

1. Use a separate USB Ethernet adapter for the temporary management subnet.
   It isolates that static address from the computer's normal LAN route.
2. If the primary adapter must be reconfigured, preserve an independent
   recovery path (for example Wi-Fi), capture the pre-state, and use a
   `try`/`finally` workflow that calls `repair-wired-dhcp.ps1` on every exit.
3. Before rebooting, verify that DHCP is enabled, a DHCP-origin address is
   preferred, and an alive default route exists. An active-store address
   disappearing at reboot is not sufficient cleanup.

Avoid unattended temporary-address commands unless they include a tested
automatic DHCP restoration path.

## Verification and tests

The 15:16 post-repair checks established all of the following:

- `Ethernet` was `Up` and connected.
- IPv4 DHCP was enabled with `192.168.1.166/24` in `Preferred` state.
- The default gateway, DHCP server, and DNS server were `192.168.1.1`.
- Windows selected `Ethernet` as the route to an external IPv4 destination.
- Gateway reachability, Internet reachability, and DNS resolution passed.

These read-only commands can repeat the state checks:

```powershell
Get-NetIPInterface -InterfaceAlias "Ethernet" -AddressFamily IPv4
Get-NetIPAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4
Get-NetRoute -InterfaceAlias "Ethernet" -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0"
Get-DnsClientServerAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4
Get-CimInstance Win32_NetworkAdapterConfiguration |
  Where-Object Description -eq (Get-NetAdapter -Name "Ethernet").InterfaceDescription |
  Select-Object DHCPEnabled, DHCPServer, IPAddress, DefaultIPGateway, DNSServerSearchOrder
Find-NetRoute -RemoteIPAddress "1.1.1.1"
Resolve-DnsName "example.com"
```

The recovery script can also be syntax-checked without changing network state:

```powershell
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\windows\repair-wired-dhcp.ps1),
  [ref]$tokens,
  [ref]$errors
)
if ($errors.Count -ne 0) { $errors; throw "PowerShell syntax check failed" }
```

Do not commit the generated JSON result: it contains machine-specific adapter
metadata and is intended as local operational evidence.

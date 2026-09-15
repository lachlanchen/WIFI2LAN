# Tao-Only Apps Without Changing the Default Router

In the dedicated-app deployment, the normal desktop uses the existing wired
router and a second USB Ethernet adapter connects to Tao's LAN without adding
a host default route or DNS server. Do not connect the two routers' LANs
together or replace the workstation's working Ethernet cable.

The launchers also work when Tao is deliberately selected as the host's
Internet connection. On September 15 the previous router stopped answering
DHCP and management requests, so the 7090 temporarily used the pinned
`Tao-Internet` profile as its working default. After a user power cycle and
independent Internet checks, the previous router regained preference (metric
100) with Tao retained at metric 600. These are separate host routing
decisions; the app installer neither makes them nor restores previous routes.

## Use

```bash
chrome-tao
terminal-tao
tao-run curl https://api.ipify.org
tao-run firefox --no-remote --profile /absolute/path/to/a/separate/profile
```

The desktop and Applications menu also contain **Chrome (Tao)**. Ordinary
Chrome is unchanged. Tao Chrome has its own profile at
`~/.config/google-chrome-tao`; it does not copy normal Chrome's credentials or
make itself the default browser. First-time sign-in is separate.

**Terminal (Tao)** is also available on the desktop and Applications menu, with
a distinct green terminal/network icon. Its Bash prompt includes `[tao]` and
loads the user's usual `~/.bashrc`, preserving aliases and configured shell
tools. External commands and their child processes use Tao. It shares the
normal home directory and credentials; this is network isolation, not a new
account or filesystem sandbox.

GNOME Terminal can delegate new windows to its existing host-side D-Bus
server. The launcher therefore starts `tao-shell` as the terminal's child,
then `tao-run` puts the actual interactive Bash process in `al-tao`. It does
not assume that starting a terminal UI inside a namespace isolates its shell.
If network preparation fails, the window reports the error and never starts
a replacement shell on the host network. An ordinary nonzero shell exit is
also reported before the window closes.

Do not assume a new tab in this window has Tao networking: use the launcher
for each new Tao shell. Likewise, use `chrome-tao` for the browser instead of
invoking an existing normal browser process from this shell. Host-side tmux
servers, containers, and other local service delegation require their own
network configuration. The `[tao]` marker identifies the launch context; it
is not a continuous connectivity indicator.

`tao-run` starts an external executable as the current desktop user inside a
network namespace attached only to Tao. GUI apps that reuse an already-running
process need their own profile or instance option; otherwise the existing
process may handle the request outside this namespace. Child processes inherit
the namespace, but apps explicitly delegating work to host services over local
IPC are outside that guarantee. Localhost means this namespace, not the host's
development servers.

## Install

Dependencies: the existing root-owned Astrill Lazy namespace helper at
`/usr/local/libexec/astrill-lazy-netns`, BusyBox, iproute2, Python 3, Google
Chrome, GNOME Terminal, and working sudo authorization. This installer does not weaken sudo
policy or install an unrestricted new privilege rule.

Review `tao.json` for the actual **second** Ethernet interface, permanent MAC,
and Tao LAN gateway. It records the 7090 adapter used for this deployment;
other computers must change those values. Then run as the desktop user:

```bash
bash ubuntu-client/install-tao-apps.sh /path/to/reviewed-tao.json
```

The installer copies reviewed launchers and a root-owned profile configuration,
then validates/prepares the app network. It does not configure a router or
change NetworkManager routes. This workstation's saved secondary profile was
created separately:

```bash
nmcli connection add type ethernet con-name Tao-Wired \
  ifname enxc8a3624ab044 802-3-ethernet.mac-address C8:A3:62:4A:B0:44 \
  connection.autoconnect yes ipv4.method auto ipv4.never-default yes \
  ipv4.ignore-auto-routes yes ipv4.ignore-auto-dns yes \
  ipv4.route-metric 600 ipv6.method disabled
```

Use the existing profile on subsequent runs, not another `connection add`.
Inspect `nmcli connection show Tao-Wired` first. Metric 600 documents its
secondary role; `never-default` is the protection that prevents even a
connectivity penalty on the primary router from promoting Tao globally.
This management-only example does **not** enable system-wide failover to Tao.
It describes the original September 14 deployment, not the September 15
`Tao-Internet` fallback profile. Do not apply it over a working fallback path
without reviewing the host's current routing requirements.

## Isolation and Recovery

The implementation reuses `astrill-lazy-netns` instead of adding a new proxy,
NAT engine, or host policy-routing system. Profile `tao` creates namespace
`al-tao` with a macvlan interface and an independent DHCP lease. Its DNS server
and sole default gateway are Tao. IPv6 is disabled only inside this namespace.
Chrome is launched with a separate profile and no system proxy; its normal
sandbox is not disabled.

`wifi2lan-app-network` checks the physical adapter MAC, carrier, namespace
parent, DHCP subnet, gateway, routes, and private resolver before launching.
An unexpected adapter or gateway is rejected. Loss of Tao does not cause
fallback to the default router. Router-managed Astrill policy still controls
whether Tao itself uses its VPN or direct WAN; namespace isolation is not an
Astrill VPN kill switch.

If an interface down/up event removes the isolated default route, the launcher
requests DHCP renewal in place. It checks the exact BusyBox executable,
arguments, PID-file identity, and network namespace before signaling the DHCP
process. It waits for recovery and validates the new route; it never installs
a guessed gateway or kills the browser to repair a missing route.

The NM profile, launchers, and configuration persist after reboot. The
namespace is recreated on the first `chrome-tao`, `terminal-tao`, or `tao-run` invocation;
Chrome does not automatically open at boot. BusyBox renews the namespace's
lease while it exists. No periodic Codex job or continuously restarting browser
service is required.

A removed/replaced USB adapter can destroy the macvlan interface. The guard
then fails closed. After closing Tao apps, remove only their namespace and
launch again with the correct adapter connected:

```bash
sudo /usr/local/libexec/astrill-lazy-netns cleanup tao
chrome-tao
```

Cleanup terminates any apps still inside that namespace, so do not run it while
they have unsaved work. The host routes and other namespaces are untouched.

## Acceptance on September 14

- Tao rebooted into a 5 GHz `tsinghua` uplink, primary channel 36.
- Astrill recovered, and `tao-run curl` used a different public IP from the
  host's normal wired path.
- Real headless Chrome rendered an HTTPS test page through Tao with its normal
  sandbox enabled.
- Taking only the app interface down made its request fail while a wired-host
  request succeeded. Relaunch preparation renewed DHCP and restored the route.
- Removing the idle test namespace and recreating it exercised the first-launch
  path used after an Ubuntu reboot. Ubuntu itself was not rebooted.
- Tao's 2.4 GHz WiFi also authenticated after the router reboot. On this
  workstation it remains disconnected with autoconnect off because the
  secondary wired adapter is preferred.

## Terminal Acceptance on September 15

- A real GNOME Terminal window opened with the Tao launcher. Its interactive
  Bash PID was verified using `sudo ip netns identify PID` as `al-tao`.
- A command launched through `tao-shell` used gateway `192.168.6.1`, reached
  an HTTPS site with status 200, and retained the user's `codex` shell command.
- Tests check the child-shell launch contract, shell syntax, preservation of
  user aliases/prompt, desktop entry, and valid icon XML.
- No host reboot, browser restart, or desktop logout was needed.

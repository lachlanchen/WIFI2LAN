# TL-WR802N v1 Wi-Fi-to-Ethernet gateway

The Chinese TL-WR802N v1 stock firmware cannot route a Wi-Fi uplink to its
Ethernet port. Its Client mode is a transparent adapter, and its Router mode
uses Ethernet as the WAN. The international WISP firmware is a different
regional branch and must not be cross-flashed.

The device-specific OpenWrt 18.06.9 factory image can provide the missing
topology:

```text
open upstream Wi-Fi -> WR802N IPv4 NAT -> Ethernet DHCP clients
```

OpenWrt support for this 4 MB flash / 32 MB RAM device is end-of-life. Use it
only as a low-trust, disposable gateway. The WAN firewall must remain enabled,
and administration must stay on the private Ethernet side. Do not expose LuCI
or SSH on the Wi-Fi WAN.

After a clean OpenWrt boot, stay connected by Ethernet and set the root
password before enabling the Wi-Fi uplink:

```sh
ssh root@192.168.1.1
passwd
exit
```

Then copy and run:

```sh
scp configure-wifi-to-lan.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 \
  "sh /tmp/configure-wifi-to-lan.sh '<upstream-ssid>'"
```

If an authorized uplink identity must be reproduced, provide its MAC as the
third argument after the fixed private LAN address. Omit it to use the
WR802N's physical radio identity:

```sh
sh /tmp/configure-wifi-to-lan.sh \
  '<upstream-ssid>' 192.168.8.1 '<authorized-mac>'
```

The final network restart changes the router from `192.168.1.1` to
`192.168.8.1`, so that SSH command is expected to disconnect and may print a
connection error even after a successful commit. Renew the Ethernet client's
DHCP lease and reconnect to `192.168.8.1`.

The final private LAN is `192.168.8.1/24`, with DHCP addresses
`192.168.8.100` through `192.168.8.199`. Wi-Fi is an open upstream station.
IPv4 is routed and masqueraded. The router may obtain IPv6 for itself, but
downstream IPv6 advertisements and forwarding are disabled.

Recovery uses the TL-WR802N v1 U-Boot TFTP path. The recovery server is
`192.168.0.66`, the router uses `192.168.0.86`, and the requested image name is
`wr802nv1_tp_recovery.bin`. Keep TFTP bound only to the isolated Ethernet
adapter and stop it immediately after recovery.

# Pi 4B Wi-Fi-to-LAN router

Target state:

```text
tsinghua -> wlan0 -> NAT -> eth0 -> 192.168.13.0/24
                                      gateway 192.168.13.1
```

The installer is written for this Pi's actual platform: Raspberry Pi 4 Model B,
32-bit Raspbian Buster, `wpa_supplicant`, and `dhcpcd`. It intentionally does not
use the newer repository helper unchanged because that helper expects
NetworkManager.

## Safe activation

The Pi is currently attached to an existing `192.168.1.0/24` Ethernet LAN. Do
not start a DHCP server while it is attached there. Instead, arm the installer
in a root-owned tmux session:

```bash
sudo tmux new-session -d -s pi4-router \
  '/home/pi/wifi-to-lan/pi4-wifi-to-lan-router.sh arm'
```

The installer waits until `eth0` has had no carrier for three seconds. Unplugging
the Pi's Ethernet cable therefore triggers the conversion without depending on
the SSH session. It then:

- assigns `192.168.13.1/24` to `eth0` through `dhcpcd`;
- serves `192.168.13.20` through `192.168.13.250` with `dnsmasq`;
- enables IPv4 forwarding and NAT through `wlan0`;
- saves one idempotent firewall rule set;
- disables Wi-Fi power saving at runtime;
- installs a boot-time oneshot service;
- writes a verification report to `~/wifi-to-lan/LAST_STATUS.txt`.

Before unplugging, inspect the waiting session with:

```bash
sudo tmux capture-pane -pt pi4-router
```

After connecting a computer to the Pi's downstream Ethernet side, it should
receive a `192.168.13.x` address. Connect to the Pi with:

```text
SSH: pi@192.168.13.1
VNC: 192.168.13.1
```

Then validate the client received DHCP, can ping `192.168.13.1`, can resolve a
domain, and can open an HTTPS website. Router-side checks alone cannot prove a
real client traversed NAT.

## Recovery

The last pre-router configuration is stored under
`/var/backups/pi4-wifi-to-lan-router/`. To restore it:

```bash
sudo /home/pi/wifi-to-lan/pi4-wifi-to-lan-router.sh rollback
```

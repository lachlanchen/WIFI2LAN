# Pi 5 reversible network modes

The Raspberry Pi 5 can use one of two safe IPv4 roles on its onboard `eth0`:

- `lan-client`: receive an address from the main router and disable Pi DHCP/NAT;
- `wifi-router`: restore the preserved `192.168.2.1` Wi-Fi-to-LAN router state.

The two roles are deliberately not active at the same time. Running the Pi's
DHCP server while `eth0` is connected to the main LAN would compete with the
main router's DHCP service.

IPv6 link-local SSH/VNC remains the recovery path during either transition.

```bash
sudo /home/lachlan/network-modes/pi5-network-mode.sh status
sudo /home/lachlan/network-modes/pi5-network-mode.sh lan-client
sudo /home/lachlan/network-modes/pi5-network-mode.sh wifi-router
```

Every transition creates a timestamped backup under
`/var/backups/pi5-network-mode/`.

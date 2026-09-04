#!/usr/bin/env bash
# Install two explicit NetworkManager Ethernet roles without a background
# controller: ordinary LAN client (default) and Wi-Fi-to-LAN server.
set -Eeuo pipefail

LAN_IF="${LAN_IF:-eth0}"
WAN_IF="${WAN_IF:-wlan0}"
CLIENT_CONNECTION="${CLIENT_CONNECTION:-pi5-lan-client}"
SERVER_CONNECTION="${SERVER_CONNECTION:-wifi-to-lan}"
LAN_CIDR="${LAN_CIDR:-192.168.23.1/24}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/pi-dual-ethernet-role}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
for command_name in nmcli ip install; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "$command_name is unavailable"
done

wifi_connection="$(nmcli -g GENERAL.CONNECTION device show "$WAN_IF")"
[ -n "$wifi_connection" ] && [ "$wifi_connection" != -- ] ||
    die "$WAN_IF must already be connected"

backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
nmcli connection show >"$backup/connections.txt"
nmcli device status >"$backup/devices.txt"
ip address >"$backup/addresses.txt"
ip route >"$backup/routes.txt"

if ! nmcli -g connection.uuid connection show "$CLIENT_CONNECTION" \
    >/dev/null 2>&1; then
    nmcli connection add type ethernet ifname "$LAN_IF" \
        con-name "$CLIENT_CONNECTION" >/dev/null
fi
nmcli connection modify "$CLIENT_CONNECTION" \
    connection.interface-name "$LAN_IF" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.never-default no \
    ipv4.route-metric 100 \
    ipv6.method auto \
    ipv6.never-default no \
    ipv6.route-metric 100

if ! nmcli -g connection.uuid connection show "$SERVER_CONNECTION" \
    >/dev/null 2>&1; then
    nmcli connection add type ethernet ifname "$LAN_IF" \
        con-name "$SERVER_CONNECTION" >/dev/null
fi
nmcli connection modify "$SERVER_CONNECTION" \
    connection.interface-name "$LAN_IF" \
    connection.autoconnect no \
    connection.autoconnect-priority 50 \
    ipv4.method shared \
    ipv4.addresses "$LAN_CIDR" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.never-default yes \
    ipv6.method disabled

nmcli connection modify "$wifi_connection" \
    connection.autoconnect yes \
    connection.autoconnect-retries 0 \
    802-11-wireless.powersave 2 \
    802-11-wireless.cloned-mac-address permanent \
    ipv4.method auto \
    ipv6.method auto

install -m 755 "$SCRIPT_DIR/pi5-ethernet-mode.sh" \
    /usr/local/sbin/pi5-ethernet-mode

echo "Dual Ethernet roles installed; client mode remains the safe default."
echo "Backup: $backup"
echo "Status: sudo pi5-ethernet-mode status"
echo "Server: sudo pi5-ethernet-mode server"
echo "Client: sudo pi5-ethernet-mode client"

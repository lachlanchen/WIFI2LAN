#!/usr/bin/env bash
# Select one of two mutually exclusive NetworkManager Ethernet profiles.
set -Eeuo pipefail

LAN_IF="${LAN_IF:-eth0}"
CLIENT_CONNECTION="${CLIENT_CONNECTION:-pi5-lan-client}"
SERVER_CONNECTION="${SERVER_CONNECTION:-wifi-to-lan}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

show_status() {
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
    echo "=== Ethernet addresses ==="
    ip -br address show "$LAN_IF"
    echo "=== Ethernet profiles ==="
    nmcli -f NAME,AUTOCONNECT,AUTOCONNECT-PRIORITY,TYPE,DEVICE \
        connection show | grep -E "^NAME|^${CLIENT_CONNECTION}|^${SERVER_CONNECTION}" || true
}

case "${1:-status}" in
    status)
        show_status
        exit 0
        ;;
    client|server)
        [ "$(id -u)" -eq 0 ] || die "run with sudo"
        ;;
    *)
        die "usage: $0 [status|client|server [--force]]"
        ;;
esac

if [ "$1" = server ]; then
    force="${2:-}"
    gateway="$(ip -4 route show default dev "$LAN_IF" 2>/dev/null |
        awk 'NR == 1 {print $3}')"
    if [ "$force" != --force ] && [ -n "$gateway" ] &&
        ping -I "$LAN_IF" -c 1 -W 1 "$gateway" >/dev/null 2>&1; then
        die "upstream gateway $gateway is reachable on $LAN_IF; move the cable to the downstream device first (or use --force)"
    fi
    nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect no
    nmcli connection modify "$SERVER_CONNECTION" connection.autoconnect yes
    nmcli --wait 30 connection up "$SERVER_CONNECTION" ifname "$LAN_IF"
    echo "Server mode active; downstream gateway is configured by $SERVER_CONNECTION."
else
    nmcli connection modify "$SERVER_CONNECTION" connection.autoconnect no
    nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect yes
    nmcli --wait 30 connection up "$CLIENT_CONNECTION" ifname "$LAN_IF"
    echo "Client mode active; DHCP lease renewed on $LAN_IF."
fi

show_status

#!/usr/bin/env bash
# Remove the simple Wi-Fi-to-LAN role and return Ethernet to an ordinary
# NetworkManager DHCP client. The active upstream Wi-Fi profile is preserved.
set -Eeuo pipefail

LAN_IF="${LAN_IF:-eth0}"
ROUTER_CONNECTION="${ROUTER_CONNECTION:-wifi-to-lan}"
CLIENT_CONNECTION="${CLIENT_CONNECTION:-Wired connection 1}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/simple-wifi-to-lan-reset}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "run with sudo"
}

connection_exists() {
    nmcli -g connection.uuid connection show "$1" >/dev/null 2>&1
}

snapshot() {
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/$stamp"
    mkdir -p "$backup"
    nmcli connection show >"$backup/connections.txt"
    nmcli device status >"$backup/devices.txt"
    ip address >"$backup/addresses.txt"
    ip route >"$backup/routes-v4.txt"
    ip -6 route >"$backup/routes-v6.txt"
    if [ -d /etc/NetworkManager/system-connections ]; then
        tar -czf "$backup/system-connections.tar.gz" \
            -C /etc/NetworkManager system-connections
    fi
    echo "Backup: $backup"
}

remove_legacy_controller() {
    systemctl disable --now \
        pi5-network-mode.service \
        pi5-network-mode-arm.service \
        pi5-network-mode-management-guard.service \
        pi5-network-mode-vnc.service >/dev/null 2>&1 || true
    command -v nft >/dev/null 2>&1 &&
        nft delete table inet pi5_management_guard >/dev/null 2>&1 || true
    rm -f \
        /etc/systemd/system/pi5-network-mode.service \
        /etc/systemd/system/pi5-network-mode-arm.service \
        /etc/systemd/system/pi5-network-mode-management-guard.service \
        /etc/systemd/system/pi5-network-mode-vnc.service \
        /etc/systemd/system/ssh.service.d/20-pi5-network-mode-guard.conf \
        /etc/systemd/system/nftables.service.d/20-pi5-network-mode-guard.conf \
        /etc/NetworkManager/dispatcher.d/90-pi5-network-mode-guard \
        /usr/local/sbin/pi5-network-mode \
        /var/lib/pi5-network-mode/mode
    systemctl daemon-reload
}

create_client_profile() {
    if connection_exists "$CLIENT_CONNECTION"; then
        client_uuid="$(nmcli -g connection.uuid connection show "$CLIENT_CONNECTION")"
    else
        client_uuid="$(
            nmcli -t -f UUID,TYPE,connection.interface-name connection show |
                awk -F: -v interface="$LAN_IF" \
                    '$2 == "802-3-ethernet" && $3 == interface { print $1; exit }'
        )"
        if [ -z "$client_uuid" ]; then
            nmcli connection add type ethernet ifname "$LAN_IF" \
                con-name "$CLIENT_CONNECTION" >/dev/null
            client_uuid="$(nmcli -g connection.uuid connection show "$CLIENT_CONNECTION")"
        fi
    fi

    nmcli connection modify "$client_uuid" \
        connection.id "$CLIENT_CONNECTION" \
        connection.interface-name "$LAN_IF" \
        connection.autoconnect yes \
        connection.autoconnect-priority 0 \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.never-default no \
        ipv6.method auto \
        ipv6.addresses "" \
        ipv6.gateway "" \
        ipv6.dns "" \
        ipv6.never-default no
}

verify() {
    connection_exists "$ROUTER_CONNECTION" &&
        die "router-sharing profile still exists"
    [ "$(nmcli -g ipv4.method connection show "$CLIENT_CONNECTION")" = auto ] ||
        die "Ethernet IPv4 is not automatic"
    [ "$(nmcli -g ipv6.method connection show "$CLIENT_CONNECTION")" = auto ] ||
        die "Ethernet IPv6 is not automatic"
    echo "Ethernet is a normal IPv4/IPv6 DHCP client."
}

main() {
    need_root
    for command_name in nmcli systemctl ip; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "$command_name is unavailable"
    done
    systemctl is-active --quiet NetworkManager.service ||
        die "NetworkManager is not active"

    snapshot
    active="$(nmcli -g GENERAL.CONNECTION device show "$LAN_IF" 2>/dev/null || true)"
    if [ "$active" = "$ROUTER_CONNECTION" ]; then
        nmcli device disconnect "$LAN_IF" >/dev/null || true
    fi
    if connection_exists "$ROUTER_CONNECTION"; then
        nmcli connection delete "$ROUTER_CONNECTION" >/dev/null
    fi
    remove_legacy_controller
    create_client_profile
    nmcli connection reload
    nmcli --wait 30 connection up "$CLIENT_CONNECTION" ifname "$LAN_IF"
    verify
}

main "$@"

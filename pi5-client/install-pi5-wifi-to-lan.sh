#!/usr/bin/env bash
# One-time Raspberry Pi OS Wi-Fi-to-LAN setup. NetworkManager owns all
# persistence, downstream DHCP/DNS, forwarding, and NAT.
set -Eeuo pipefail

LAN_IF="${LAN_IF:-eth0}"
WAN_IF="${WAN_IF:-wlan0}"
LAN_CIDR="${LAN_CIDR:-192.168.23.1/24}"
ROUTER_CONNECTION="${ROUTER_CONNECTION:-wifi-to-lan}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/simple-wifi-to-lan}"
ACTIVATE_CONNECTED="${ACTIVATE_CONNECTED:-0}"
MIGRATE_LEGACY="${MIGRATE_LEGACY:-1}"

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

backup_path() {
    local source="$1"
    local backup="$2"
    [ -e "$source" ] || return 0
    mkdir -p "$backup/legacy$(dirname "$source")"
    cp -a "$source" "$backup/legacy$source"
}

delete_iptables_rule() {
    local table="$1"
    shift
    command -v iptables >/dev/null 2>&1 || return 0
    while iptables ${table:+-t "$table"} -C "$@" >/dev/null 2>&1; do
        iptables ${table:+-t "$table"} -D "$@"
    done
}

disable_old_controller() {
    local backup="$1"
    local path
    for path in \
        /etc/systemd/system/pi5-network-mode.service \
        /etc/systemd/system/pi5-network-mode-arm.service \
        /etc/systemd/system/pi5-network-mode-management-guard.service \
        /etc/systemd/system/pi5-network-mode-vnc.service \
        /etc/systemd/system/ssh.service.d/20-pi5-network-mode-guard.conf \
        /etc/systemd/system/nftables.service.d/20-pi5-network-mode-guard.conf \
        /etc/NetworkManager/dispatcher.d/90-pi5-network-mode-guard \
        /usr/local/sbin/pi5-network-mode; do
        backup_path "$path" "$backup"
    done

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

disable_legacy_static_router() {
    local backup="$1"
    local interfaces_file="/etc/network/interfaces.d/$LAN_IF"
    local dnsmasq_file="/etc/dnsmasq.d/bridge.conf"
    local old_service="pi-wifi-to-lan-router-fix.service"
    local old_script="/home/lachlan/scripts/pi-wifi-to-lan-router-fix.sh"
    local path

    [ "$MIGRATE_LEGACY" = 1 ] || return 0

    # Migrate only the older layout created by this project's static-router
    # script. Every removed file is preserved under the timestamped backup.
    backup_path "$old_script" "$backup"
    if systemctl list-unit-files "$old_service" --no-legend 2>/dev/null |
        grep -q "^$old_service"; then
        systemctl disable --now "$old_service" >/dev/null 2>&1 || true
        backup_path "/etc/systemd/system/$old_service" "$backup"
        rm -f "/etc/systemd/system/$old_service"
    fi

    if [ -f "$interfaces_file" ] &&
        grep -Eq "^[[:space:]]*iface[[:space:]]+$LAN_IF[[:space:]]+inet[[:space:]]+static" "$interfaces_file"; then
        backup_path "$interfaces_file" "$backup"
        rm -f "$interfaces_file"
    fi

    if [ -f "$dnsmasq_file" ] &&
        grep -Eq "^[[:space:]]*interface=$LAN_IF([[:space:]]|$)" "$dnsmasq_file"; then
        backup_path "$dnsmasq_file" "$backup"
        rm -f "$dnsmasq_file"
        systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
    fi

    for path in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        backup_path "$path" "$backup"
    done
    delete_iptables_rule "" FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
    delete_iptables_rule "" FORWARD -i "$WAN_IF" -o "$LAN_IF" \
        -m state --state RELATED,ESTABLISHED -j ACCEPT
    delete_iptables_rule nat POSTROUTING -o "$WAN_IF" -j MASQUERADE
    delete_iptables_rule mangle POSTROUTING -o "$WAN_IF" -j TTL --ttl-set 65
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    nmcli general reload
    nmcli device set "$LAN_IF" managed yes >/dev/null 2>&1 || true
    if [ "$(nmcli -g GENERAL.NM-MANAGED device show "$LAN_IF" 2>/dev/null || true)" != yes ]; then
        # The ifupdown plugin marks configured devices strictly unmanaged and
        # only forgets that classification after NetworkManager restarts.
        systemctl restart NetworkManager.service
        for _ in $(seq 1 30); do
            nmcli -g GENERAL.STATE device show "$LAN_IF" >/dev/null 2>&1 && break
            sleep 1
        done
        nmcli device set "$LAN_IF" managed yes >/dev/null 2>&1 || true
    fi
    [ "$(nmcli -g GENERAL.NM-MANAGED device show "$LAN_IF" 2>/dev/null || true)" = yes ] ||
        die "$LAN_IF remains unmanaged after legacy migration"
}

show_status() {
    echo "=== devices ==="
    nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
    echo "=== router profile ==="
    nmcli -g connection.id,connection.interface-name,connection.autoconnect,\
ipv4.method,ipv4.addresses,ipv4.never-default,ipv6.method \
        connection show "$ROUTER_CONNECTION" 2>/dev/null || true
    echo "=== addresses ==="
    ip -br address show "$WAN_IF" || true
    ip -br address show "$LAN_IF" || true
    echo "=== routes ==="
    ip -4 route
    ip -6 route | sed -n '1,20p'
    echo "=== downstream services ==="
    pgrep -af '[d]nsmasq.*nm-dnsmasq' || true
    if command -v nft >/dev/null 2>&1; then
        nft list table ip "nm-shared-$LAN_IF" 2>/dev/null | sed -n '1,120p' || true
    fi
}

install_router() {
    need_root
    for command_name in nmcli systemctl ip; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "$command_name is unavailable"
    done

    systemctl enable --now NetworkManager.service >/dev/null
    wifi_connection="$(nmcli -g GENERAL.CONNECTION device show "$WAN_IF")"
    [ -n "$wifi_connection" ] && [ "$wifi_connection" != -- ] ||
        die "$WAN_IF must already be connected to the intended upstream Wi-Fi"

    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$BACKUP_ROOT/$stamp"
    mkdir -p "$backup"
    nmcli connection show >"$backup/connections.txt"
    nmcli device status >"$backup/devices.txt"
    ip address >"$backup/addresses.txt"
    ip route >"$backup/routes.txt"

    disable_old_controller "$backup"
    disable_legacy_static_router "$backup"

    nmcli connection modify "$wifi_connection" \
        connection.autoconnect yes \
        connection.autoconnect-priority 999 \
        802-11-wireless.powersave 2 \
        ipv4.method auto \
        ipv4.never-default no \
        ipv6.method auto \
        ipv6.never-default no

    if ! connection_exists "$ROUTER_CONNECTION"; then
        nmcli connection add type ethernet ifname "$LAN_IF" \
            con-name "$ROUTER_CONNECTION" >/dev/null
    fi
    nmcli connection modify "$ROUTER_CONNECTION" \
        connection.interface-name "$LAN_IF" \
        connection.autoconnect yes \
        connection.autoconnect-priority 999 \
        ipv4.method shared \
        ipv4.addresses "$LAN_CIDR" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.never-default yes \
        ipv6.method disabled

    router_uuid="$(nmcli -g connection.uuid connection show "$ROUTER_CONNECTION")"
    while IFS=: read -r uuid type; do
        [ "$type" = 802-3-ethernet ] || continue
        [ "$uuid" = "$router_uuid" ] && continue
        nmcli connection modify "$uuid" connection.autoconnect no
    done < <(nmcli -t -f UUID,TYPE connection show)

    # Stopping the former management guard can also stop SSH because the old
    # drop-in made SSH depend on that guard. Start SSH again after removing it.
    systemctl enable --now ssh.service >/dev/null 2>&1 || true
    nmcli connection reload

    active="$(nmcli -g GENERAL.CONNECTION device show "$LAN_IF" 2>/dev/null || true)"
    if [ "$active" = "$ROUTER_CONNECTION" ]; then
        echo "Wi-Fi-to-LAN is already active."
    elif [ "$ACTIVATE_CONNECTED" = 1 ] ||
        [ "$(cat "/sys/class/net/$LAN_IF/carrier" 2>/dev/null || echo 0)" = 0 ]; then
        nmcli --wait 30 connection up "$ROUTER_CONNECTION" ifname "$LAN_IF"
        echo "Wi-Fi-to-LAN activated."
    else
        echo "Setup is permanent and ready."
        echo "Move $LAN_IF from the existing LAN to the downstream WAN/device."
        echo "After the link reconnects, NetworkManager activates it automatically."
    fi
    echo "Downstream gateway: ${LAN_CIDR%/*}"
    echo "Upstream Wi-Fi remains an IPv4 and IPv6 client."
    echo "Backup: $backup"
    show_status
}

case "${1:-install}" in
    install)
        install_router
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: sudo $0 [install|status]" >&2
        exit 2
        ;;
esac

#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_CONNECTION="${CLIENT_CONNECTION:-pi5-lan-client}"
LAN_IF="${LAN_IF:-eth0}"
WAN_CONNECTION="${WAN_CONNECTION:-tsinghua}"
WAN_IF="${WAN_IF:-wlan0}"
ROUTER_SERVICE="${ROUTER_SERVICE:-pi-wifi-to-lan-router-fix.service}"
ROUTER_ADDRESS="${ROUTER_ADDRESS:-192.168.2.1/24}"
MODE_DIR="/etc/pi5-network-mode"
BACKUP_ROOT="/var/backups/pi5-network-mode"
ROUTER_INTERFACES="/etc/network/interfaces.d/eth0"
SAVED_ROUTER_INTERFACES="$MODE_DIR/eth0.router"
CLIENT_SYSCTL="/etc/sysctl.d/99-z-pi5-lan-client.conf"
CLIENT_NM_CONF="/etc/NetworkManager/conf.d/30-pi5-lan-client.conf"
LOG_FILE="/var/log/pi5-network-mode.log"

usage() {
  cat <<EOF
Usage: sudo $0 {lan-client|wifi-router|status}

  lan-client   Join the main LAN by DHCP; disable Pi DHCP/NAT services.
  wifi-router  Restore the saved Wi-Fi-to-LAN router role at 192.168.2.1.
  status       Show the current mode, interfaces, services, and routes.
EOF
}

log() {
  local message="[$(date '+%F %T')] $*"
  printf '%s\n' "$message"
  [ "${EUID:-$(id -u)}" -ne 0 ] || printf '%s\n' "$message" >>"$LOG_FILE"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
}

preflight() {
  grep -q 'Raspberry Pi 5 Model B' /proc/device-tree/model 2>/dev/null ||
    die "this mode switch is locked to a Raspberry Pi 5 Model B"
  grep -q 'VERSION_CODENAME=bookworm' /etc/os-release 2>/dev/null ||
    die "this mode switch expects Debian Bookworm"
  for command_name in nmcli ip iptables systemctl sysctl netfilter-persistent; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
  done
  [ -d "/sys/class/net/$LAN_IF" ] || die "missing interface: $LAN_IF"
}

backup_state() {
  local stamp backup
  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup="$BACKUP_ROOT/$stamp"
  mkdir -p "$backup" "$MODE_DIR"
  iptables-save >"$backup/iptables.v4"
  ip -br address >"$backup/ip-addresses.txt"
  ip route >"$backup/ip-routes.txt"
  nmcli connection show >"$backup/nm-connections.txt"
  systemctl cat "$ROUTER_SERVICE" >"$backup/router-service.txt" 2>&1 || true
  cp -a /etc/dnsmasq.d "$backup/dnsmasq.d"
  cp -a /etc/sysctl.d "$backup/sysctl.d"
  if [ -e "$ROUTER_INTERFACES" ]; then
    cp -a "$ROUTER_INTERFACES" "$backup/eth0.interfaces"
    if [ ! -e "$SAVED_ROUTER_INTERFACES" ]; then
      install -o root -g root -m 0644 "$ROUTER_INTERFACES" "$SAVED_ROUTER_INTERFACES"
    fi
  fi
  printf '%s\n' "$backup" >"$MODE_DIR/last-backup"
  log "Backup created at $backup"
}

delete_all_rules() {
  local table="$1"
  shift
  if [ -n "$table" ]; then
    while iptables -t "$table" -C "$@" >/dev/null 2>&1; do
      iptables -t "$table" -D "$@"
    done
  else
    while iptables -C "$@" >/dev/null 2>&1; do
      iptables -D "$@"
    done
  fi
}

remove_router_rules() {
  delete_all_rules "" FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
  delete_all_rules "" FORWARD -i "$WAN_IF" -o "$LAN_IF" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
  delete_all_rules "" FORWARD -i "$WAN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  delete_all_rules nat POSTROUTING -o "$WAN_IF" -j MASQUERADE
  delete_all_rules mangle POSTROUTING -o "$WAN_IF" -j TTL --ttl-set 65
  netfilter-persistent save >/dev/null
}

configure_client_profile() {
  if nmcli -t -f NAME connection show | grep -Fxq "$CLIENT_CONNECTION"; then
    nmcli connection modify "$CLIENT_CONNECTION" \
      connection.interface-name "$LAN_IF" \
      connection.autoconnect yes \
      ipv4.method auto \
      ipv4.never-default no \
      ipv4.route-metric 100 \
      ipv6.method auto \
      ipv6.never-default no
  else
    nmcli connection add type ethernet ifname "$LAN_IF" \
      con-name "$CLIENT_CONNECTION" \
      connection.autoconnect yes \
      ipv4.method auto \
      ipv4.route-metric 100 \
      ipv6.method auto
  fi
}

lan_client() {
  require_root
  preflight
  backup_state
  log "Switching $LAN_IF to safe LAN-client mode"

  systemctl disable --now "$ROUTER_SERVICE" 2>/dev/null || true
  systemctl disable --now dnsmasq.service 2>/dev/null || true
  remove_router_rules

  cat >"$CLIENT_SYSCTL" <<'EOF'
# Managed by pi5-network-mode.sh while the Pi is a normal LAN client.
net.ipv4.ip_forward=0
net.ipv4.ip_default_ttl=64
EOF
  sysctl -q -w net.ipv4.ip_forward=0
  sysctl -q -w net.ipv4.ip_default_ttl=64

  rm -f "$ROUTER_INTERFACES"
  install -d -o root -g root -m 0755 "$(dirname "$CLIENT_NM_CONF")"
  cat >"$CLIENT_NM_CONF" <<EOF
# Managed by pi5-network-mode.sh while eth0 is a normal LAN client.
[ifupdown]
managed=true
EOF
  configure_client_profile
  # NetworkManager must restart to forget the former ifupdown-owned interface.
  systemctl restart NetworkManager.service
  for attempt in $(seq 1 15); do
    if [ "$(nmcli -g GENERAL.STATE device show "$LAN_IF" 2>/dev/null || true)" != "10 (unmanaged)" ]; then
      break
    fi
    sleep 1
  done
  nmcli device set "$LAN_IF" managed yes
  ip -4 address flush dev "$LAN_IF"
  nmcli connection up "$CLIENT_CONNECTION" ifname "$LAN_IF"

  local address gateway
  address="$(ip -4 -o address show dev "$LAN_IF" scope global | awk 'NR == 1 {print $4}')"
  gateway="$(ip -4 route show default dev "$LAN_IF" | awk 'NR == 1 {print $3}')"
  [ -n "$address" ] || die "$LAN_IF did not receive an IPv4 DHCP lease"
  [ -n "$gateway" ] || die "$LAN_IF did not receive an IPv4 default route"
  systemctl is-active --quiet dnsmasq.service && die "dnsmasq is still active"

  log "LAN-client mode active: address=$address gateway=$gateway"
  status
}

wifi_router() {
  require_root
  preflight
  backup_state
  [ -r "$SAVED_ROUTER_INTERFACES" ] || die "saved router interface config is missing"
  log "Restoring Wi-Fi-to-LAN router mode"

  nmcli connection down "$CLIENT_CONNECTION" 2>/dev/null || true
  nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect no 2>/dev/null || true
  install -o root -g root -m 0644 "$SAVED_ROUTER_INTERFACES" "$ROUTER_INTERFACES"
  rm -f "$CLIENT_SYSCTL"
  rm -f "$CLIENT_NM_CONF"
  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w net.ipv4.ip_default_ttl=65
  systemctl restart NetworkManager.service
  nmcli device set "$LAN_IF" managed no 2>/dev/null || true
  ip -4 address flush dev "$LAN_IF"
  ip address add "$ROUTER_ADDRESS" dev "$LAN_IF"
  systemctl enable --now dnsmasq.service
  systemctl enable --now "$ROUTER_SERVICE"
  log "Wi-Fi-router mode restored at $ROUTER_ADDRESS"
  status
}

status() {
  printf '%s\n' '=== interfaces ==='
  ip -br address show "$LAN_IF" || true
  ip -br address show "$WAN_IF" || true
  printf '%s\n' '=== routes ==='
  ip -4 route || true
  printf '%s\n' '=== active NetworkManager connections ==='
  nmcli -t -f NAME,TYPE,DEVICE connection show --active || true
  printf '%s\n' '=== services ==='
  printf 'router enabled: '; systemctl is-enabled "$ROUTER_SERVICE" 2>&1 || true
  printf 'router active:  '; systemctl is-active "$ROUTER_SERVICE" 2>&1 || true
  printf 'dnsmasq enabled: '; systemctl is-enabled dnsmasq.service 2>&1 || true
  printf 'dnsmasq active:  '; systemctl is-active dnsmasq.service 2>&1 || true
  printf 'ssh active:      '; systemctl is-active ssh.service 2>&1 || true
  printf 'VNC port:        '
  ss -lnt | awk '$4 ~ /:5900$/ {print "active"; found=1} END {if (!found) print "missing"}'
  printf '%s\n' '=== forwarding ==='
  sysctl net.ipv4.ip_forward net.ipv4.ip_default_ttl || true
}

main() {
  case "${1:-}" in
    lan-client) lan_client ;;
    wifi-router) wifi_router ;;
    status) require_root; preflight; status ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"

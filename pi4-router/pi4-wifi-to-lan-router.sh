#!/usr/bin/env bash
set -Eeuo pipefail

WAN_IF="${WAN_IF:-wlan0}"
LAN_IF="${LAN_IF:-eth0}"
LAN_CIDR="${LAN_CIDR:-192.168.13.1/24}"
LAN_IP="${LAN_IP:-192.168.13.1}"
DHCP_RANGE="${DHCP_RANGE:-192.168.13.20,192.168.13.250,12h}"
EXPECTED_SSID="${EXPECTED_SSID:-tsinghua}"
TTL="${TTL:-65}"

PROGRAM_NAME="pi4-wifi-to-lan-router"
INSTALL_PATH="/usr/local/sbin/${PROGRAM_NAME}.sh"
STATE_DIR="/var/lib/${PROGRAM_NAME}"
BACKUP_ROOT="/var/backups/${PROGRAM_NAME}"
LOG_FILE="/var/log/${PROGRAM_NAME}.log"
STATUS_FILE="/home/pi/wifi-to-lan/LAST_STATUS.txt"
DHCPCD_CONF="/etc/dhcpcd.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/${PROGRAM_NAME}.conf"
SYSCTL_CONF="/etc/sysctl.d/99-${PROGRAM_NAME}.conf"
SERVICE_FILE="/etc/systemd/system/${PROGRAM_NAME}.service"
BEGIN_MARKER="# BEGIN ${PROGRAM_NAME}"
END_MARKER="# END ${PROGRAM_NAME}"

usage() {
  cat <<EOF
Usage: sudo $0 ACTION

Actions:
  preflight      Validate this Pi, packages, Wi-Fi, and intended addresses.
  arm            Wait for the current Ethernet cable to be unplugged, then apply.
  apply          Apply immediately. Use only when eth0 is isolated downstream.
  apply-runtime  Reassert the already-installed runtime state (used at boot).
  status         Show configuration and run non-destructive checks.
  rollback       Restore the configuration saved by the most recent apply.

Router shape: ${WAN_IF} (${EXPECTED_SSID}) -> NAT -> ${LAN_IF} (${LAN_CIDR})
EOF
}

log() {
  local message="[$(date '+%F %T')] $*"
  printf '%s\n' "$message"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    printf '%s\n' "$message" >>"$LOG_FILE"
  fi
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run this action with sudo"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

assert_supported_host() {
  [ -d "/sys/class/net/$WAN_IF" ] || die "missing upstream interface: $WAN_IF"
  [ -d "/sys/class/net/$LAN_IF" ] || die "missing downstream interface: $LAN_IF"
  grep -q 'Raspberry Pi 4 Model B' /proc/device-tree/model 2>/dev/null ||
    die "this installer is locked to a Raspberry Pi 4 Model B"
  grep -q 'VERSION_CODENAME=buster' /etc/os-release 2>/dev/null ||
    die "this installer expects Raspbian Buster with dhcpcd"
}

wifi_status_value() {
  /sbin/wpa_cli -i "$WAN_IF" status 2>/dev/null |
    awk -F= -v key="$1" '$1 == key { print $2; exit }'
}

assert_wifi_uplink() {
  local state ssid address gateway
  state="$(wifi_status_value wpa_state)"
  ssid="$(wifi_status_value ssid)"
  address="$(wifi_status_value ip_address)"
  gateway="$(ip -4 route show default dev "$WAN_IF" | awk 'NR == 1 {print $3}')"

  [ "$state" = "COMPLETED" ] || die "$WAN_IF is not associated (state=${state:-unknown})"
  [ "$ssid" = "$EXPECTED_SSID" ] ||
    die "$WAN_IF is on '${ssid:-unknown}', expected '$EXPECTED_SSID'"
  [ -n "$address" ] || die "$WAN_IF has no IPv4 address"
  [ -n "$gateway" ] || die "$WAN_IF has no IPv4 default route"
}

wait_for_wifi_uplink() {
  local attempt
  for attempt in $(seq 1 60); do
    if [ "$(wifi_status_value wpa_state)" = "COMPLETED" ] &&
       [ "$(wifi_status_value ssid)" = "$EXPECTED_SSID" ] &&
       [ -n "$(wifi_status_value ip_address)" ] &&
       ip -4 route show default dev "$WAN_IF" | grep -q '^default '; then
      return 0
    fi
    sleep 1
  done
  assert_wifi_uplink
}

backup_path() {
  local source="$1" destination="$2"
  if [ -e "$source" ] || [ -L "$source" ]; then
    cp -a "$source" "$destination"
  else
    : >"${destination}.absent"
  fi
}

create_backup() {
  local stamp backup_dir
  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_dir="$BACKUP_ROOT/$stamp"
  mkdir -p "$backup_dir" "$STATE_DIR"
  backup_path "$DHCPCD_CONF" "$backup_dir/dhcpcd.conf"
  backup_path "$DNSMASQ_CONF" "$backup_dir/dnsmasq.conf"
  backup_path "$SYSCTL_CONF" "$backup_dir/sysctl.conf"
  backup_path "$SERVICE_FILE" "$backup_dir/service.conf"
  iptables-save >"$backup_dir/iptables.v4"
  printf '%s\n' "$backup_dir" >"$STATE_DIR/last-backup"
  log "Backup created at $backup_dir"
}

restore_path() {
  local saved="$1" target="$2"
  if [ -e "$saved" ] || [ -L "$saved" ]; then
    install -d "$(dirname "$target")"
    cp -a "$saved" "$target"
  elif [ -e "${saved}.absent" ]; then
    rm -f "$target"
  fi
}

write_dhcpcd_config() {
  local temporary
  temporary="$(mktemp)"
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    !skip       { print }
  ' "$DHCPCD_CONF" >"$temporary"
  cat >>"$temporary" <<EOF

${BEGIN_MARKER}
interface ${LAN_IF}
static ip_address=${LAN_CIDR}
nogateway
${END_MARKER}
EOF
  install -o root -g root -m 0644 "$temporary" "$DHCPCD_CONF"
  rm -f "$temporary"
}

write_dnsmasq_config() {
  cat >"$DNSMASQ_CONF" <<EOF
# Managed by ${PROGRAM_NAME}.sh
interface=${LAN_IF}
bind-dynamic
listen-address=${LAN_IP}
dhcp-authoritative
dhcp-range=${DHCP_RANGE}
dhcp-option=option:router,${LAN_IP}
dhcp-option=option:dns-server,${LAN_IP}
domain-needed
bogus-priv
EOF
  chmod 0644 "$DNSMASQ_CONF"
  dnsmasq --test
}

write_sysctl_config() {
  cat >"$SYSCTL_CONF" <<EOF
# Managed by ${PROGRAM_NAME}.sh
net.ipv4.ip_forward=1
net.ipv4.ip_default_ttl=${TTL}
EOF
  chmod 0644 "$SYSCTL_CONF"
}

write_service() {
  if [ "$(readlink -f "$0")" != "$(readlink -m "$INSTALL_PATH")" ]; then
    install -o root -g root -m 0755 "$0" "$INSTALL_PATH"
  fi
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Raspberry Pi 4 Wi-Fi-to-LAN router
Wants=network-online.target
After=dhcpcd.service wpa_supplicant.service network-online.target netfilter-persistent.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply-runtime
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "${PROGRAM_NAME}.service" >/dev/null
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

ensure_one_rule() {
  local table="$1"
  shift
  delete_all_rules "$table" "$@"
  if [ -n "$table" ]; then
    iptables -t "$table" -A "$@"
  else
    iptables -A "$@"
  fi
}

apply_firewall() {
  ensure_one_rule "" FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
  ensure_one_rule "" FORWARD -i "$WAN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ensure_one_rule nat POSTROUTING -o "$WAN_IF" -j MASQUERADE

  delete_all_rules mangle POSTROUTING -o "$WAN_IF" -j TTL --ttl-set "$TTL"
  if ! iptables -t mangle -A POSTROUTING -o "$WAN_IF" -j TTL --ttl-set "$TTL"; then
    log "WARN: TTL target is unavailable; NAT routing can still operate"
  fi
  netfilter-persistent save >/dev/null
}

apply_runtime() {
  require_root
  assert_supported_host
  for command_name in ip iptables iptables-save sysctl dnsmasq \
    netfilter-persistent systemctl dhcpcd iw ping curl; do
    require_command "$command_name"
  done
  wait_for_wifi_uplink

  log "Applying runtime router state"
  sysctl -q -w net.ipv4.ip_forward=1
  sysctl -q -w "net.ipv4.ip_default_ttl=$TTL"
  iw dev "$WAN_IF" set power_save off 2>/dev/null || true

  # Reload dhcpcd so it forgets the old Ethernet DHCP lease and owns the new
  # static configuration on future carrier changes.
  dhcpcd -n "$LAN_IF" 2>/dev/null || true
  sleep 1
  ip link set "$LAN_IF" up
  ip -4 addr flush dev "$LAN_IF"
  ip addr add "$LAN_CIDR" dev "$LAN_IF"
  ip route del default dev "$LAN_IF" 2>/dev/null || true

  apply_firewall
  dnsmasq --test
  systemctl enable dnsmasq.service >/dev/null
  systemctl restart dnsmasq.service
  log "Runtime router state applied"
}

assert_router_state() {
  local failures=0 gateway
  check() {
    if "$@" >/dev/null 2>&1; then
      printf 'PASS  %s\n' "$*"
    else
      printf 'FAIL  %s\n' "$*"
      failures=$((failures + 1))
    fi
  }

  gateway="$(ip -4 route show default dev "$WAN_IF" | awk 'NR == 1 {print $3}')"
  check test "$(wifi_status_value wpa_state)" = COMPLETED
  check test "$(wifi_status_value ssid)" = "$EXPECTED_SSID"
  check test -n "$(wifi_status_value ip_address)"
  check test -n "$gateway"
  has_lan_address() {
    ip -o -4 addr show dev "$LAN_IF" | awk '{print $4}' | grep -Fxq "$LAN_CIDR"
  }
  check has_lan_address
  check test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1
  check systemctl is-active --quiet dnsmasq.service
  check dnsmasq --test
  check iptables -C FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
  check iptables -C FORWARD -i "$WAN_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  check iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE
  check ping -I "$WAN_IF" -c 1 -W 3 "$gateway"
  check curl --interface "$WAN_IF" -4 -fsS --max-time 15 -o /dev/null https://www.baidu.com/

  if [ "$failures" -ne 0 ]; then
    printf 'RESULT: %s check(s) failed\n' "$failures"
    return 1
  fi
  printf 'RESULT: all router-side checks passed\n'
}

show_status() {
  printf '%s\n' '=== identity ==='
  hostname
  tr '\000' '\n' </proc/device-tree/model 2>/dev/null || true
  printf '%s\n' '=== Wi-Fi ==='
  /sbin/wpa_cli -i "$WAN_IF" status 2>/dev/null |
    grep -E '^(ssid|wpa_state|ip_address)=' || true
  printf '%s\n' '=== addresses/routes ==='
  ip -br addr show "$WAN_IF" || true
  ip -br addr show "$LAN_IF" || true
  ip -4 route || true
  printf '%s\n' '=== forwarding ==='
  sysctl net.ipv4.ip_forward net.ipv4.ip_default_ttl || true
  printf '%s\n' '=== services ==='
  systemctl is-enabled "${PROGRAM_NAME}.service" 2>&1 || true
  systemctl is-active "${PROGRAM_NAME}.service" 2>&1 || true
  systemctl is-enabled dnsmasq.service 2>&1 || true
  systemctl is-active dnsmasq.service 2>&1 || true
  printf '%s\n' '=== firewall ==='
  iptables -S FORWARD || true
  iptables -t nat -S POSTROUTING || true
  iptables -t mangle -S POSTROUTING || true
  printf '%s\n' '=== assertions ==='
  assert_router_state
}

apply_install() {
  require_root
  assert_supported_host
  require_command tmux
  require_command dnsmasq
  require_command netfilter-persistent
  assert_wifi_uplink
  create_backup
  write_dhcpcd_config
  write_dnsmasq_config
  write_sysctl_config
  write_service
  apply_runtime
  systemctl start "${PROGRAM_NAME}.service"
  install -d -o pi -g pi -m 0755 "$(dirname "$STATUS_FILE")"
  if show_status >"$STATUS_FILE" 2>&1; then
    chown pi:pi "$STATUS_FILE"
    log "All router-side checks passed; report: $STATUS_FILE"
  else
    chown pi:pi "$STATUS_FILE"
    log "ERROR: one or more router checks failed; report: $STATUS_FILE"
    return 1
  fi
}

preflight() {
  require_root
  assert_supported_host
  for command_name in ip iptables iptables-save sysctl dnsmasq \
    netfilter-persistent systemctl dhcpcd iw ping curl tmux; do
    require_command "$command_name"
  done
  assert_wifi_uplink
  [ "$LAN_IP" = "${LAN_CIDR%/*}" ] || die "LAN_IP and LAN_CIDR do not match"
  dnsmasq --version | sed -n '1p'
  tmux -V
  printf 'Wi-Fi: %s at %s\n' "$(wifi_status_value ssid)" "$(wifi_status_value ip_address)"
  printf 'Planned LAN: %s on %s\n' "$LAN_CIDR" "$LAN_IF"
  printf 'Preflight passed\n'
}

arm_after_disconnect() {
  require_root
  assert_supported_host
  assert_wifi_uplink
  log "ARMED: waiting for $LAN_IF carrier to go down before router activation"
  log "This prevents DHCP from starting on the current 192.168.1.x LAN"
  local down_count=0
  while [ "$down_count" -lt 3 ]; do
    if [ "$(cat "/sys/class/net/$LAN_IF/carrier" 2>/dev/null || echo 0)" = 0 ]; then
      down_count=$((down_count + 1))
    else
      down_count=0
    fi
    sleep 1
  done
  log "$LAN_IF stayed disconnected for 3 seconds; activating router"
  apply_install
}

rollback() {
  require_root
  local backup_dir
  [ -r "$STATE_DIR/last-backup" ] || die "no backup record exists"
  backup_dir="$(cat "$STATE_DIR/last-backup")"
  [ -d "$backup_dir" ] || die "backup directory is missing: $backup_dir"

  log "Rolling back from $backup_dir"
  systemctl disable --now "${PROGRAM_NAME}.service" 2>/dev/null || true
  systemctl disable --now dnsmasq.service 2>/dev/null || true
  restore_path "$backup_dir/dhcpcd.conf" "$DHCPCD_CONF"
  restore_path "$backup_dir/dnsmasq.conf" "$DNSMASQ_CONF"
  restore_path "$backup_dir/sysctl.conf" "$SYSCTL_CONF"
  restore_path "$backup_dir/service.conf" "$SERVICE_FILE"
  iptables-restore <"$backup_dir/iptables.v4"
  systemctl daemon-reload
  systemctl restart dhcpcd.service
  netfilter-persistent save >/dev/null
  log "Rollback complete"
}

main() {
  case "${1:-}" in
    preflight)
      preflight
      ;;
    arm)
      arm_after_disconnect
      ;;
    apply)
      apply_install
      ;;
    apply-runtime)
      apply_runtime
      ;;
    status)
      require_root
      show_status
      ;;
    rollback)
      rollback
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"

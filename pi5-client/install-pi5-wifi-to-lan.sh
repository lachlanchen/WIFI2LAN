#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="pi5-network-mode"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_MANAGER="${SCRIPT_DIR}/pi5-network-mode.sh"
INSTALL_PATH="/usr/local/sbin/${PROGRAM_NAME}"
STATE_DIR="/var/lib/${PROGRAM_NAME}"
BACKUP_ROOT="/var/backups/${PROGRAM_NAME}"
MODE_SERVICE="/etc/systemd/system/${PROGRAM_NAME}.service"
ARM_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-arm.service"
GUARD_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-management-guard.service"
VNC_SERVICE="/etc/systemd/system/${PROGRAM_NAME}-vnc.service"
SYSCTL_FILE="/etc/sysctl.d/90-${PROGRAM_NAME}.conf"
SSH_GUARD_DROPIN="/etc/systemd/system/ssh.service.d/20-${PROGRAM_NAME}-guard.conf"
NFT_GUARD_DROPIN="/etc/systemd/system/nftables.service.d/20-${PROGRAM_NAME}-guard.conf"
NM_DISPATCHER="/etc/NetworkManager/dispatcher.d/90-${PROGRAM_NAME}-guard"

CLIENT_CONNECTION="${CLIENT_CONNECTION:-pi5-lan-client}"
ROUTER_CONNECTION="${ROUTER_CONNECTION:-pi5-wifi-router}"
UPSTREAM_CONNECTION="${UPSTREAM_CONNECTION:-pi5-tsinghua}"
LAN_IF="${LAN_IF:-eth0}"
WAN_IF="${WAN_IF:-wlan0}"
EXPECTED_SSID="${EXPECTED_SSID:-tsinghua}"
ROUTER_CIDR="${ROUTER_CIDR:-192.168.2.1/24}"
WIFI_COUNTRY="${WIFI_COUNTRY:-CN}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  log "WARN: $*" >&2
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

assert_host() {
  local codename model
  model="$(tr '\000' '\n' </proc/device-tree/model 2>/dev/null || true)"
  case "$model" in
    *"Raspberry Pi 5"*) ;;
    *) die "this installer is locked to Raspberry Pi 5 (found: ${model:-unknown})" ;;
  esac

  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"
  case "$codename" in
    bookworm|trixie) ;;
    *) die "expected Raspberry Pi OS Bookworm or Trixie (found: ${codename:-unknown})" ;;
  esac
  [ -d "/sys/class/net/$LAN_IF" ] || die "missing interface: $LAN_IF"
  [ -d "/sys/class/net/$WAN_IF" ] || die "missing interface: $WAN_IF"
}

backup_path() {
  local source="$1" destination="$2"
  if [ -e "$source" ] || [ -L "$source" ]; then
    cp -a "$source" "$destination"
  else
    : >"${destination}.absent"
  fi
}

backup_state() {
  local backup stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup="${BACKUP_ROOT}/install-${stamp}"
  install -d -o root -g root -m 0700 "$backup"
  backup_path "$INSTALL_PATH" "$backup/pi5-network-mode"
  backup_path "$MODE_SERVICE" "$backup/pi5-network-mode.service"
  backup_path "$ARM_SERVICE" "$backup/pi5-network-mode-arm.service"
  backup_path "$GUARD_SERVICE" "$backup/pi5-network-mode-management-guard.service"
  backup_path "$VNC_SERVICE" "$backup/pi5-network-mode-vnc.service"
  backup_path "$SYSCTL_FILE" "$backup/sysctl.conf"
  backup_path "$SSH_GUARD_DROPIN" "$backup/ssh-guard.conf"
  backup_path "$NFT_GUARD_DROPIN" "$backup/nftables-guard.conf"
  backup_path "$NM_DISPATCHER" "$backup/networkmanager-guard-dispatcher"
  nmcli connection show >"$backup/connections.txt" 2>/dev/null || true
  ip -br address >"$backup/addresses.txt" 2>/dev/null || true
  ip -4 route >"$backup/routes-v4.txt" 2>/dev/null || true
  log "Pre-install backup: $backup"
}

connection_exists() {
  nmcli -t -f NAME connection show | grep -Fxq "$1"
}

ensure_ethernet_profile() {
  local name="$1"
  if connection_exists "$name"; then
    if [ "$(nmcli -g connection.type connection show "$name")" != 802-3-ethernet ]; then
      nmcli connection delete "$name" >/dev/null
      nmcli connection add type ethernet ifname "$LAN_IF" con-name "$name" >/dev/null
    fi
  else
    nmcli connection add type ethernet ifname "$LAN_IF" con-name "$name" >/dev/null
  fi
}

write_profiles() {
  ensure_ethernet_profile "$CLIENT_CONNECTION"
  nmcli connection modify "$CLIENT_CONNECTION" \
    connection.interface-name "$LAN_IF" \
    connection.autoconnect yes \
    connection.autoconnect-priority 999 \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.never-default no \
    ipv4.route-metric 50 \
    ipv6.method auto \
    ipv6.addresses "" \
    ipv6.gateway "" \
    ipv6.dns "" \
    ipv6.never-default no \
    ipv6.route-metric 50

  ensure_ethernet_profile "$ROUTER_CONNECTION"
  nmcli connection modify "$ROUTER_CONNECTION" \
    connection.interface-name "$LAN_IF" \
    connection.autoconnect no \
    connection.autoconnect-priority 999 \
    ipv4.method shared \
    ipv4.addresses "$ROUTER_CIDR" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.never-default yes \
    ipv6.method disabled \
    ipv6.addresses "" \
    ipv6.gateway "" \
    ipv6.dns ""

  # Recreate only our own Wi-Fi profile. Omitting a wireless-security setting
  # is deliberate: tsinghua is an open SSID and no secret is stored here.
  if connection_exists "$UPSTREAM_CONNECTION"; then
    nmcli connection delete "$UPSTREAM_CONNECTION" >/dev/null
  fi
  nmcli connection add type wifi ifname "$WAN_IF" con-name "$UPSTREAM_CONNECTION" \
    ssid "$EXPECTED_SSID" >/dev/null
  nmcli connection modify "$UPSTREAM_CONNECTION" \
    connection.interface-name "$WAN_IF" \
    connection.autoconnect yes \
    connection.autoconnect-priority 999 \
    802-11-wireless.mode infrastructure \
    ipv4.method auto \
    ipv4.never-default no \
    ipv4.route-metric 600 \
    ipv6.method auto \
    ipv6.never-default no \
    ipv6.route-metric 600
}

write_units() {
  cat >"$MODE_SERVICE" <<EOF
[Unit]
Description=Raspberry Pi 5 safe network-mode restoration
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} apply-saved
RemainAfterExit=yes
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

  cat >"$ARM_SERVICE" <<EOF
[Unit]
Description=Raspberry Pi 5 physical Wi-Fi-router cutover
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} arm-wait
Restart=on-failure
RestartSec=30
TimeoutStartSec=infinity
EOF

  cat >"$GUARD_SERVICE" <<EOF
[Unit]
Description=Block Pi management ports on the open Wi-Fi uplink
Wants=NetworkManager.service
After=NetworkManager.service nftables.service
Before=ssh.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} firewall-apply
ExecReload=${INSTALL_PATH} firewall-apply
ExecStop=${INSTALL_PATH} firewall-remove
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat >"$VNC_SERVICE" <<EOF
[Unit]
Description=Enable Raspberry Pi VNC after desktop autologin is ready
Requires=${PROGRAM_NAME}-management-guard.service
After=display-manager.service ${PROGRAM_NAME}-management-guard.service
ConditionPathExists=!${STATE_DIR}/vnc-enabled

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} vnc-enable
Restart=on-failure
RestartSec=15
TimeoutStartSec=150

[Install]
WantedBy=graphical.target
EOF

  install -d -o root -g root -m 0755 \
    "$(dirname "$SSH_GUARD_DROPIN")" "$(dirname "$NFT_GUARD_DROPIN")" \
    "$(dirname "$NM_DISPATCHER")"
  cat >"$SSH_GUARD_DROPIN" <<EOF
[Unit]
Requires=${PROGRAM_NAME}-management-guard.service
After=${PROGRAM_NAME}-management-guard.service
EOF
  cat >"$NFT_GUARD_DROPIN" <<EOF
[Service]
ExecStartPost=${INSTALL_PATH} firewall-apply
ExecReload=${INSTALL_PATH} firewall-apply
EOF
  cat >"$NM_DISPATCHER" <<EOF
#!/bin/sh
case "\${1:-}:\${2:-}" in
  ${WAN_IF}:up|${WAN_IF}:connectivity-change)
    ${INSTALL_PATH} firewall-apply
    ;;
esac
EOF
  chmod 0644 "$MODE_SERVICE" "$ARM_SERVICE" "$GUARD_SERVICE" "$VNC_SERVICE" \
    "$SSH_GUARD_DROPIN" "$NFT_GUARD_DROPIN"
  chmod 0755 "$NM_DISPATCHER"
}

enable_remote_access() {
  systemctl enable --now ssh.service
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_ssh 0
    raspi-config nonint do_wifi_country "$WIFI_COUNTRY" ||
      warn "could not set Wi-Fi country to $WIFI_COUNTRY"
    [ -e /etc/systemd/system/display-manager.service ] ||
      die "no display manager found; use Raspberry Pi OS with Desktop for VNC"
    raspi-config nonint do_boot_behaviour B4 ||
      die "could not enable Desktop Autologin (B4), which delayed VNC setup requires"
    rm -f "${STATE_DIR}/vnc-enabled"
  else
    die "raspi-config is missing; cannot verify that VNC is enabled"
  fi
}

install_missing_packages() {
  local -a packages=()
  command -v nmcli >/dev/null 2>&1 || packages+=(network-manager)
  command -v dnsmasq >/dev/null 2>&1 || packages+=(dnsmasq-base)
  command -v nft >/dev/null 2>&1 || packages+=(nftables)
  command -v sshd >/dev/null 2>&1 || packages+=(openssh-server)
  if [ "${#packages[@]}" -eq 0 ]; then
    log "Required networking and remote-access packages are already present"
    return 0
  fi

  require_command apt-get
  log "Missing required packages: ${packages[*]}"
  apt-get update ||
    die "package index refresh failed; connect wired Internet and rerun (safe mode is unchanged)"
  apt-get install -y --no-install-recommends "${packages[@]}" ||
    die "package installation failed; restore Internet access and rerun"
}

main() {
  local command_name firewall_backend mode_temporary
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
  [ -r "$SOURCE_MANAGER" ] || die "missing $SOURCE_MANAGER"
  assert_host

  export DEBIAN_FRONTEND=noninteractive
  install_missing_packages

  for command_name in NetworkManager nmcli dnsmasq nft ip sysctl systemctl ss sshd awk grep sed; do
    require_command "$command_name"
  done
  systemctl enable --now NetworkManager.service

  firewall_backend="$(NetworkManager --print-config 2>/dev/null |
    awk -F= '/^[[:space:]]*firewall-backend[[:space:]]*=/ {
      gsub(/[[:space:]]/, "", $2); print $2; exit
    }')"
  [ "$firewall_backend" != none ] ||
    die "NetworkManager firewall-backend=none cannot provide router NAT"

  # Fail closed as early as possible. If a reinstall is interrupted, a later
  # boot must never restore a previously selected DHCP/router role. Leave an
  # active connection alone until the final safe-mode step so a remote update
  # can still finish over its existing transport.
  install -d -o root -g root -m 0755 "$STATE_DIR"
  mode_temporary="$(mktemp "${STATE_DIR}/.mode.XXXXXX")"
  printf 'lan-client\n' >"$mode_temporary"
  chmod 0644 "$mode_temporary"
  mv -f "$mode_temporary" "${STATE_DIR}/mode"
  if connection_exists "$ROUTER_CONNECTION"; then
    nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no
  fi
  backup_state

  install -o root -g root -m 0755 "$SOURCE_MANAGER" "$INSTALL_PATH"
  cat >"$SYSCTL_FILE" <<'EOF'
# Managed by pi5-network-mode. Wi-Fi remains an IPv6 host, never an IPv6 router.
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
EOF
  chmod 0644 "$SYSCTL_FILE"

  # A standalone dnsmasq service must never answer on the main LAN. The
  # NetworkManager shared profile launches its own interface-scoped DHCP/DNS
  # helper only while the isolated router profile is active.
  systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
  systemctl disable --now pi-wifi-to-lan-router-fix.service >/dev/null 2>&1 || true

  write_units
  systemctl daemon-reload
  systemctl enable --now "${PROGRAM_NAME}-management-guard.service" >/dev/null
  write_profiles
  enable_remote_access
  systemctl enable "${PROGRAM_NAME}.service" >/dev/null
  systemctl enable "${PROGRAM_NAME}-vnc.service" >/dev/null
  if systemctl is-active --quiet graphical.target; then
    systemctl start --no-block "${PROGRAM_NAME}-vnc.service"
  fi
  "$INSTALL_PATH" install-safe

  log "Installation complete in safe lan-client mode"
  log "Wi-Fi profile: open SSID $EXPECTED_SSID (IPv4 + IPv6 client)"
  log "Router profile: $LAN_IF at $ROUTER_CIDR (IPv4 DHCP/DNS/NAT only)"
  log "When ready: sudo $INSTALL_PATH arm, then unplug $LAN_IF from the main LAN"
}

main "$@"

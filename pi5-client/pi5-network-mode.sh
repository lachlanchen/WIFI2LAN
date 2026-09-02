#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM_NAME="pi5-network-mode"
INSTALL_PATH="/usr/local/sbin/${PROGRAM_NAME}"
CLIENT_CONNECTION="${CLIENT_CONNECTION:-pi5-lan-client}"
ROUTER_CONNECTION="${ROUTER_CONNECTION:-pi5-wifi-router}"
UPSTREAM_CONNECTION="${UPSTREAM_CONNECTION:-pi5-tsinghua}"
LAN_IF="${LAN_IF:-eth0}"
WAN_IF="${WAN_IF:-wlan0}"
EXPECTED_SSID="${EXPECTED_SSID:-tsinghua}"
ROUTER_CIDR="${ROUTER_CIDR:-192.168.2.1/24}"
ROUTER_IP="${ROUTER_IP:-192.168.2.1}"
STATE_DIR="/var/lib/${PROGRAM_NAME}"
MODE_FILE="${STATE_DIR}/mode"
BACKUP_ROOT="/var/backups/${PROGRAM_NAME}"
ARM_SERVICE="${PROGRAM_NAME}-arm.service"
GUARD_TABLE="pi5_management_guard"
VNC_MARKER="${STATE_DIR}/vnc-enabled"

usage() {
  cat <<EOF
Usage: sudo $0 ACTION

Actions:
  status                         Show saved mode and live network state.
  verify                         Check the safety and routing invariants.
  arm                            Supervise a physical cable-unplug cutover.
  cancel-arm                     Cancel a waiting physical cutover.
  lan-client                     Stop sharing and make eth0 a DHCP client.
  wifi-router --confirm-isolated Select router mode only while eth0 is unplugged.

The installed default is lan-client. The safe remote workflow is "arm", then
unplug eth0 from the main LAN for five seconds. NetworkManager will activate
the 192.168.2.1/24 shared profile when eth0 is connected downstream.
EOF
}

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

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run this action with sudo"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

ipv4_to_u32() {
  local a b c d
  IFS=. read -r a b c d <<<"${1%%/*}"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && [ "$((10#$octet))" -le 255 ] ||
      die "invalid IPv4 address: $1"
  done
  printf '%u\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

cidr_overlaps() {
  local left="$1" right="$2" left_prefix right_prefix prefix mask left_u32 right_u32
  left_prefix="${left##*/}"
  right_prefix="${right##*/}"
  [[ "$left_prefix" =~ ^[0-9]+$ ]] && [ "$left_prefix" -le 32 ] ||
    die "invalid IPv4 prefix: $left"
  [[ "$right_prefix" =~ ^[0-9]+$ ]] && [ "$right_prefix" -le 32 ] ||
    die "invalid IPv4 prefix: $right"
  left_u32="$(ipv4_to_u32 "$left")"
  right_u32="$(ipv4_to_u32 "$right")"
  if [ "$left_prefix" -lt "$right_prefix" ]; then
    prefix="$left_prefix"
  else
    prefix="$right_prefix"
  fi
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  fi
  [ "$((left_u32 & mask))" -eq "$((right_u32 & mask))" ]
}

cidr_network() {
  local cidr="$1" prefix value mask network
  prefix="${cidr##*/}"
  value="$(ipv4_to_u32 "$cidr")"
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  fi
  network=$((value & mask))
  printf '%u.%u.%u.%u/%u\n' \
    "$(((network >> 24) & 255))" \
    "$(((network >> 16) & 255))" \
    "$(((network >> 8) & 255))" \
    "$((network & 255))" "$prefix"
}

assert_router_subnet_not_on_wifi() {
  local wifi_cidr
  while IFS= read -r wifi_cidr; do
    [ -n "$wifi_cidr" ] || continue
    if cidr_overlaps "$ROUTER_CIDR" "$wifi_cidr"; then
      die "downstream $ROUTER_CIDR overlaps Wi-Fi network $wifi_cidr; choose another ROUTER_CIDR"
    fi
  done < <(ip -4 -o address show dev "$WAN_IF" scope global | awk '{print $4}')
}

assert_networkmanager_firewall() {
  local backend
  backend="$(NetworkManager --print-config 2>/dev/null |
    awk -F= '/^[[:space:]]*firewall-backend[[:space:]]*=/ {
      gsub(/[[:space:]]/, "", $2); print $2; exit
    }')"
  [ "$backend" != none ] ||
    die "NetworkManager firewall-backend=none cannot provide router NAT"
}

connection_count() {
  local expected="$1"
  nmcli -t -f NAME connection show |
    awk -v expected="$expected" '$0 == expected { count++ } END { print count + 0 }'
}

connection_exists() {
  [ "$(connection_count "$1")" -gt 0 ]
}

require_one_connection() {
  local count name="$1"
  count="$(connection_count "$name")"
  [ "$count" -eq 1 ] || die "expected exactly one profile named $name (found: $count)"
}

connection_property_is() {
  local connection="$1" property="$2" expected="$3"
  [ "$(nmcli -g "$property" connection show "$connection")" = "$expected" ]
}

connection_active() {
  [ "$(nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null || true)" = "$2" ]
}

carrier_value() {
  cat "/sys/class/net/${LAN_IF}/carrier" 2>/dev/null || printf '0\n'
}

read_mode() {
  if [ -r "$MODE_FILE" ]; then
    tr -d '[:space:]' <"$MODE_FILE"
  else
    printf 'lan-client\n'
  fi
}

write_mode() {
  local mode="$1" temporary
  install -d -o root -g root -m 0755 "$STATE_DIR" || return 1
  temporary="$(mktemp "${STATE_DIR}/.mode.XXXXXX")" || return 1
  if ! printf '%s\n' "$mode" >"$temporary" ||
     ! chmod 0644 "$temporary" ||
     ! mv -f "$temporary" "$MODE_FILE"; then
    rm -f "$temporary"
    return 1
  fi
}

assert_supported_host() {
  local codename model
  model="$(tr '\000' '\n' </proc/device-tree/model 2>/dev/null || true)"
  case "$model" in
    *"Raspberry Pi 5"*) ;;
    *) die "this mode manager is locked to Raspberry Pi 5 (found: ${model:-unknown})" ;;
  esac

  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"
  case "$codename" in
    bookworm|trixie) ;;
    *) die "expected Raspberry Pi OS Bookworm or Trixie (found: ${codename:-unknown})" ;;
  esac

  [ -d "/sys/class/net/$LAN_IF" ] || die "missing downstream interface: $LAN_IF"
  [ -d "/sys/class/net/$WAN_IF" ] || die "missing upstream interface: $WAN_IF"
  systemctl is-active --quiet NetworkManager.service || die "NetworkManager is not active"
}

recovery_preflight() {
  local command_name
  for command_name in nmcli ip sysctl systemctl awk; do
    require_command "$command_name"
  done
  [ -d "/sys/class/net/$LAN_IF" ] || die "missing downstream interface: $LAN_IF"
  systemctl is-active --quiet NetworkManager.service || die "NetworkManager is not active"
}

preflight() {
  local command_name
  for command_name in NetworkManager nmcli nft ip sysctl systemctl ss pgrep awk grep sed; do
    require_command "$command_name"
  done
  assert_supported_host
  assert_networkmanager_firewall
  require_one_connection "$CLIENT_CONNECTION"
  require_one_connection "$ROUTER_CONNECTION"
  require_one_connection "$UPSTREAM_CONNECTION"

  connection_property_is "$CLIENT_CONNECTION" connection.type 802-3-ethernet ||
    die "$CLIENT_CONNECTION is not an Ethernet profile"
  connection_property_is "$CLIENT_CONNECTION" connection.interface-name "$LAN_IF" ||
    die "$CLIENT_CONNECTION is not locked to $LAN_IF"
  connection_property_is "$CLIENT_CONNECTION" ipv4.method auto ||
    die "$CLIENT_CONNECTION must be an IPv4 DHCP client"
  connection_property_is "$CLIENT_CONNECTION" ipv6.method auto ||
    die "$CLIENT_CONNECTION must be an IPv6 client"

  connection_property_is "$ROUTER_CONNECTION" connection.type 802-3-ethernet ||
    die "$ROUTER_CONNECTION is not an Ethernet profile"
  connection_property_is "$ROUTER_CONNECTION" connection.interface-name "$LAN_IF" ||
    die "$ROUTER_CONNECTION is not locked to $LAN_IF"
  connection_property_is "$ROUTER_CONNECTION" ipv4.method shared ||
    die "$ROUTER_CONNECTION is not an IPv4 shared profile"
  connection_property_is "$ROUTER_CONNECTION" ipv4.addresses "$ROUTER_CIDR" ||
    die "$ROUTER_CONNECTION must use exactly $ROUTER_CIDR"
  connection_property_is "$ROUTER_CONNECTION" ipv4.never-default yes ||
    die "$ROUTER_CONNECTION must never install a default route"
  connection_property_is "$ROUTER_CONNECTION" ipv6.method disabled ||
    die "$ROUTER_CONNECTION must have IPv6 disabled"

  connection_property_is "$UPSTREAM_CONNECTION" connection.type 802-11-wireless ||
    die "$UPSTREAM_CONNECTION is not a Wi-Fi profile"
  connection_property_is "$UPSTREAM_CONNECTION" connection.interface-name "$WAN_IF" ||
    die "$UPSTREAM_CONNECTION is not locked to $WAN_IF"
  connection_property_is "$UPSTREAM_CONNECTION" 802-11-wireless.ssid "$EXPECTED_SSID" ||
    die "$UPSTREAM_CONNECTION does not target SSID $EXPECTED_SSID"
  connection_property_is "$UPSTREAM_CONNECTION" 802-11-wireless.mode infrastructure ||
    die "$UPSTREAM_CONNECTION must use Wi-Fi infrastructure mode"
  connection_property_is "$UPSTREAM_CONNECTION" ipv4.method auto ||
    die "$UPSTREAM_CONNECTION must be an IPv4 client"
  connection_property_is "$UPSTREAM_CONNECTION" ipv6.method auto ||
    die "$UPSTREAM_CONNECTION must be an IPv6 client"
}

snapshot_state() {
  local backup stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup="${BACKUP_ROOT}/${stamp}"
  install -d -o root -g root -m 0700 "$backup"
  nmcli connection show >"$backup/connections.txt"
  nmcli device status >"$backup/devices.txt"
  ip -br address >"$backup/addresses.txt"
  ip -4 route >"$backup/routes-v4.txt"
  ip -6 route >"$backup/routes-v6.txt"
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
    >"$backup/forwarding.txt" 2>&1 || true
  if [ -r "$MODE_FILE" ]; then
    cp -a "$MODE_FILE" "$backup/mode"
  fi
  log "State snapshot: $backup"
}

enforce_no_ipv6_routing() {
  sysctl -q -w net.ipv6.conf.all.forwarding=0
  sysctl -q -w net.ipv6.conf.default.forwarding=0
}

firewall_apply() {
  # Keep weak-password management services off the open campus Wi-Fi without
  # owning or flushing NetworkManager's separate DHCP/NAT tables.
  nft delete table inet "$GUARD_TABLE" >/dev/null 2>&1 || true
  nft -f - <<EOF
table inet ${GUARD_TABLE} {
  chain input {
    type filter hook input priority -5; policy accept;
    iifname "${WAN_IF}" tcp dport { 22, 5900 } counter drop comment "block management on open Wi-Fi"
  }
}
EOF
  log "Management guard active: TCP 22/5900 blocked only on $WAN_IF"
}

firewall_remove() {
  nft delete table inet "$GUARD_TABLE" >/dev/null 2>&1 || true
}

enable_vnc_after_desktop() {
  local attempt runtime_dir user_name user_uid
  require_command find
  require_command getent
  require_command pgrep
  require_command raspi-config
  user_name="$(getent passwd 1000 | awk -F: 'NR == 1 {print $1}')"
  user_uid="$(id -u "$user_name" 2>/dev/null || true)"
  [ "$user_uid" = 1000 ] || die "cannot identify the Raspberry Pi desktop user (UID 1000)"
  runtime_dir="/run/user/${user_uid}"

  # On current Raspberry Pi OS, raspi-config selects the VNC backend from the
  # running desktop. Wait for the autologin compositor instead of guessing too
  # early during imaging/cloud-init.
  for attempt in $(seq 1 120); do
    if find "$runtime_dir" -maxdepth 1 -type s -name 'wayland-*' -print -quit \
         2>/dev/null | grep -q . || pgrep -x Xorg >/dev/null 2>&1; then
      raspi-config nonint do_vnc 0
      for attempt in $(seq 1 60); do
        if ss -lnt | awk '$4 ~ /:5900$/ { found=1 } END { exit !found }'; then
          install -d -o root -g root -m 0755 "$STATE_DIR"
          printf 'enabled for UID 1000 (%s) at %s\n' "$user_name" "$(date --iso-8601=seconds)" \
            >"$VNC_MARKER"
          chmod 0644 "$VNC_MARKER"
          log "VNC enabled and verified on TCP 5900 for $user_name"
          return 0
        fi
        sleep 1
      done
      die "VNC was enabled but TCP 5900 did not start; setup will retry"
    fi
    sleep 1
  done
  die "desktop session did not become ready; VNC enablement will retry"
}

normalize_client_profile() {
  local count
  count="$(connection_count "$CLIENT_CONNECTION")"
  if [ "$count" -eq 0 ]; then
    nmcli connection add type ethernet ifname "$LAN_IF" \
      con-name "$CLIENT_CONNECTION" >/dev/null
  elif [ "$count" -ne 1 ]; then
    die "cannot safely normalize $CLIENT_CONNECTION: found $count profiles with that name"
  elif ! connection_property_is "$CLIENT_CONNECTION" connection.type 802-3-ethernet; then
    nmcli connection delete "$CLIENT_CONNECTION" >/dev/null
    nmcli connection add type ethernet ifname "$LAN_IF" \
      con-name "$CLIENT_CONNECTION" >/dev/null
  fi

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
}

disable_lan_sharing_profiles() {
  local active_uuid failures=0 interface method profile_type uuid
  active_uuid="$(nmcli -g GENERAL.CON-UUID device show "$LAN_IF" 2>/dev/null || true)"
  while IFS= read -r uuid; do
    [ -n "$uuid" ] || continue
    profile_type="$(nmcli -g connection.type connection show "$uuid" 2>/dev/null || true)"
    method="$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null || true)"
    interface="$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null || true)"
    if [ "$profile_type" = 802-3-ethernet ] && [ "$method" = shared ] &&
       { [ -z "$interface" ] || [ "$interface" = "$LAN_IF" ] || [ "$uuid" = "$active_uuid" ]; }; then
      if ! nmcli connection modify "$uuid" connection.autoconnect no; then
        warn "could not disable sharing-profile autoconnect for $uuid"
        failures=1
      fi
      nmcli --wait 10 connection down "$uuid" >/dev/null 2>&1 || true
    fi
  done < <(nmcli -t -f UUID connection show)
  return "$failures"
}

apply_client_mode() {
  local activate="${1:-yes}" persist_mode="${2:-yes}" safety_failure=0

  # Recovery must tear down sharing even if a profile was deleted or corrupted.
  # Disconnecting the device also stops NetworkManager's private dnsmasq and NAT
  # before the known-good DHCP-client profile is normalized and reactivated.
  if connection_exists "$ROUTER_CONNECTION"; then
    nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no || {
      warn "could not disable router-profile autoconnect"
      safety_failure=1
    }
    nmcli --wait 10 connection down "$ROUTER_CONNECTION" >/dev/null 2>&1 || true
  fi
  disable_lan_sharing_profiles || safety_failure=1
  nmcli --wait 10 device disconnect "$LAN_IF" >/dev/null 2>&1 || true
  systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
  systemctl disable --now pi-wifi-to-lan-router-fix.service >/dev/null 2>&1 || true
  sysctl -q -w net.ipv4.ip_forward=0 || safety_failure=1
  sysctl -q -w net.ipv6.conf.all.forwarding=0 || safety_failure=1
  sysctl -q -w net.ipv6.conf.default.forwarding=0 || safety_failure=1
  if [ "$persist_mode" = yes ]; then
    write_mode lan-client || safety_failure=1
  fi
  normalize_client_profile

  if [ "$activate" = yes ] && [ "$(carrier_value)" = 1 ]; then
    nmcli --wait 30 connection up "$CLIENT_CONNECTION" ifname "$LAN_IF" >/dev/null
  fi
  [ "$safety_failure" -eq 0 ] || die "client mode is active, but one safety setting could not be persisted"
  log "$LAN_IF is now a normal IPv4/IPv6 DHCP client; router sharing is off"
}

ensure_wifi_upstream() {
  local attempt address default_route
  nmcli --wait 15 connection up "$UPSTREAM_CONNECTION" ifname "$WAN_IF" >/dev/null 2>&1 || true
  for attempt in $(seq 1 30); do
    address="$(ip -4 -o address show dev "$WAN_IF" scope global | awk 'NR == 1 {print $4}')"
    default_route="$(ip -4 route show default dev "$WAN_IF" | awk 'NR == 1 {print $0}')"
    if connection_active "$WAN_IF" "$UPSTREAM_CONNECTION" &&
       [ -n "$address" ] && [ -n "$default_route" ]; then
      assert_router_subnet_not_on_wifi
      log "Wi-Fi upstream ready on $EXPECTED_SSID at $address"
      return 0
    fi
    sleep 1
  done
  die "$WAN_IF did not establish an IPv4 default route through $EXPECTED_SSID"
}

select_router_mode() {
  local rollback_needed=yes
  [ "$(carrier_value)" = 0 ] ||
    die "$LAN_IF still has carrier; unplug it before enabling DHCP/router mode"

  rollback_router_selection() {
    if [ "$rollback_needed" = yes ]; then
      nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no >/dev/null 2>&1 || true
      nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect yes >/dev/null 2>&1 || true
      write_mode lan-client >/dev/null 2>&1 || true
    fi
  }
  trap rollback_router_selection ERR

  nmcli connection down "$CLIENT_CONNECTION" >/dev/null 2>&1 || true
  [ "$(carrier_value)" = 0 ] || die "$LAN_IF carrier returned during cutover; staying safe"
  nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect no
  # Never persist an autoconnecting DHCP server. The supervised watcher will
  # explicitly activate this profile only after isolation and reconnection.
  nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no
  enforce_no_ipv6_routing
  write_mode wifi-router
  rollback_needed=no
  trap - ERR

  log "Router mode selected while $LAN_IF was physically disconnected"
  log "Connect $LAN_IF only to the downstream device; activation is still supervised"
}

activate_router_after_reconnect() {
  local activation_started=no

  rollback_active_router() {
    if [ "$activation_started" = yes ]; then
      nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no >/dev/null 2>&1 || true
      nmcli --wait 10 connection down "$ROUTER_CONNECTION" >/dev/null 2>&1 || true
      nmcli connection modify "$CLIENT_CONNECTION" connection.autoconnect yes >/dev/null 2>&1 || true
      sysctl -q -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
      enforce_no_ipv6_routing >/dev/null 2>&1 || true
      warn "router activation failed verification and was torn down"
    fi
  }
  trap rollback_active_router ERR

  log "Waiting for $LAN_IF to reconnect to the downstream device"
  while [ "$(carrier_value)" != 1 ]; do
    sleep 1
  done

  # Wi-Fi may have changed while the cable was moving. Revalidate both the
  # upstream and the non-overlap invariant before starting DHCP/NAT.
  ensure_wifi_upstream
  [ "$(carrier_value)" = 1 ] ||
    die "$LAN_IF lost carrier before router activation; re-arm the cutover"
  nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no
  [ "$(carrier_value)" = 1 ] ||
    die "$LAN_IF lost carrier at the final activation check; re-arm the cutover"
  activation_started=yes
  nmcli --wait 30 connection up "$ROUTER_CONNECTION" ifname "$LAN_IF" >/dev/null
  nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no
  if ! verify; then
    rollback_active_router
    trap - ERR
    return 1
  fi
  activation_started=no
  trap - ERR
  log "Router mode active at $ROUTER_IP; DHCP/DNS/NAT is scoped to $LAN_IF"
}

arm_wait() {
  local down_count=0
  preflight
  ensure_wifi_upstream
  nmcli connection modify "$ROUTER_CONNECTION" connection.autoconnect no
  log "ARMED: waiting for $LAN_IF carrier to stay down for five seconds"
  log "Unplug $LAN_IF from the main LAN; do not reconnect it there in router mode"

  while [ "$down_count" -lt 5 ]; do
    if [ "$(carrier_value)" = 0 ]; then
      down_count=$((down_count + 1))
    else
      down_count=0
    fi
    sleep 1
  done
  snapshot_state
  select_router_mode
  activate_router_after_reconnect
}

arm() {
  systemctl start --no-block "$ARM_SERVICE"
  log "Physical cutover is armed in systemd"
  log "Follow it with: journalctl -fu $ARM_SERVICE"
}

cancel_arm() {
  systemctl stop "$ARM_SERVICE"
  snapshot_state || warn "could not save a cancellation snapshot; continuing fail-closed"
  apply_client_mode yes
  log "Physical cutover cancelled; lan-client mode is enforced"
}

apply_saved_mode() {
  local saved_mode
  saved_mode="$(read_mode)"
  case "$saved_mode" in
    lan-client)
      apply_client_mode yes
      ;;
    wifi-router)
      # A cable's carrier cannot identify whether it is connected downstream
      # or to the main LAN. Reboots therefore re-arm the physical isolation
      # handshake instead of unconditionally restoring a DHCP server.
      apply_client_mode yes no
      preflight
      systemctl start --no-block "$ARM_SERVICE"
      log "Saved router mode re-armed; unplug $LAN_IF for five seconds, then reconnect downstream"
      ;;
    *)
      warn "invalid saved mode '$saved_mode'; enforcing lan-client"
      apply_client_mode yes
      return 1
      ;;
  esac
}

service_state() {
  local unit="$1"
  printf '%-30s enabled=%-10s active=%s\n' "$unit" \
    "$(systemctl is-enabled "$unit" 2>/dev/null || true)" \
    "$(systemctl is-active "$unit" 2>/dev/null || true)"
}

show_status() {
  printf '%s\n' '=== saved role ==='
  printf 'mode=%s\n' "$(read_mode)"
  printf 'arm-service=%s\n' "$(systemctl is-active "$ARM_SERVICE" 2>/dev/null || true)"
  printf '%s\n' '=== interfaces ==='
  ip -br address show "$WAN_IF" || true
  ip -br address show "$LAN_IF" || true
  printf 'eth0-carrier=%s\n' "$(carrier_value)"
  printf '%s\n' '=== routes ==='
  ip -4 route || true
  ip -6 route || true
  printf '%s\n' '=== active NetworkManager connections ==='
  nmcli -t -f NAME,TYPE,DEVICE connection show --active || true
  printf '%s\n' '=== managed profile invariants ==='
  nmcli -g connection.id,connection.autoconnect,ipv4.method,ipv4.addresses,ipv6.method \
    connection show "$CLIENT_CONNECTION" || true
  nmcli -g connection.id,connection.autoconnect,ipv4.method,ipv4.addresses,ipv6.method \
    connection show "$ROUTER_CONNECTION" || true
  nmcli -g connection.id,connection.autoconnect,802-11-wireless.ssid,ipv4.method,ipv6.method \
    connection show "$UPSTREAM_CONNECTION" || true
  printf '%s\n' '=== forwarding ==='
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding || true
  printf '%s\n' '=== management guard ==='
  nft list table inet "$GUARD_TABLE" 2>&1 || true
  printf '%s\n' '=== remote access ==='
  service_state ssh.service
  service_state "${PROGRAM_NAME}-vnc.service"
  service_state wayvnc.service
  service_state vncserver-x11-serviced.service
  if [ -r "$VNC_MARKER" ]; then
    printf 'VNC marker: '; cat "$VNC_MARKER"
  else
    printf 'VNC marker: pending graphical-session enablement\n'
  fi
  ss -lnt | awk '$4 ~ /:22$/ || $4 ~ /:5900$/ {print}'
}

verify() {
  local failures=0 mode router_active router_network
  mode="$(read_mode)"
  router_network="$(cidr_network "$ROUTER_CIDR")"
  router_active=no
  connection_active "$LAN_IF" "$ROUTER_CONNECTION" && router_active=yes

  check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
      printf 'PASS  %s\n' "$description"
    else
      printf 'FAIL  %s\n' "$description"
      failures=$((failures + 1))
    fi
  }

  check 'saved mode is valid' grep -Eq '^(lan-client|wifi-router)$' "$MODE_FILE"
  check 'router uses NetworkManager IPv4 sharing' test \
    "$(nmcli -g ipv4.method connection show "$ROUTER_CONNECTION")" = shared
  check 'router address is 192.168.2.1/24' sh -c \
    "nmcli -g ipv4.addresses connection show '$ROUTER_CONNECTION' | grep -Fq '$ROUTER_CIDR'"
  check 'downstream IPv6 is disabled' test \
    "$(nmcli -g ipv6.method connection show "$ROUTER_CONNECTION")" = disabled
  check 'Wi-Fi is an IPv4 client' test \
    "$(nmcli -g ipv4.method connection show "$UPSTREAM_CONNECTION")" = auto
  check 'Wi-Fi is an IPv6 client' test \
    "$(nmcli -g ipv6.method connection show "$UPSTREAM_CONNECTION")" = auto
  check 'kernel IPv6 forwarding is off' test "$(sysctl -n net.ipv6.conf.all.forwarding)" = 0
  check 'management guard table exists' nft list table inet "$GUARD_TABLE"
  check 'SSH is blocked on the open Wi-Fi interface' sh -c \
    "nft list chain inet '$GUARD_TABLE' input | grep -F 'iifname \"$WAN_IF\"' | grep -Fq 'tcp dport { 22, 5900 }'"
  check 'SSH is enabled' systemctl is-enabled --quiet ssh.service

  if [ "$mode" = lan-client ]; then
    check 'client profile autoconnects in client mode' test \
      "$(nmcli -g connection.autoconnect connection show "$CLIENT_CONNECTION")" = yes
    check 'router profile cannot autoconnect in client mode' test \
      "$(nmcli -g connection.autoconnect connection show "$ROUTER_CONNECTION")" = no
    check 'router profile is inactive in client mode' test "$router_active" = no
    check 'IPv4 forwarding is off in client mode' test "$(sysctl -n net.ipv4.ip_forward)" = 0
  elif [ "$router_active" = yes ]; then
    check 'router activation is supervised, not persistent autoconnect' test \
      "$(nmcli -g connection.autoconnect connection show "$ROUTER_CONNECTION")" = no
    check 'client profile stays disabled while router is active' test \
      "$(nmcli -g connection.autoconnect connection show "$CLIENT_CONNECTION")" = no
    check 'router profile has the gateway address' sh -c \
      "ip -4 -o address show dev '$LAN_IF' | awk '{print \$4}' | grep -Fxq '$ROUTER_CIDR'"
    check 'IPv4 forwarding is active with sharing' test "$(sysctl -n net.ipv4.ip_forward)" = 1
    check 'NetworkManager DHCP/DNS helper has an eth0 PID file' test -s \
      "/run/nm-dnsmasq-${LAN_IF}.pid"
    check 'NetworkManager DHCP/DNS helper serves the router address' sh -c \
      "pgrep -af '[d]nsmasq' | grep -F -- '--pid-file=/run/nm-dnsmasq-$LAN_IF.pid' | grep -Fq -- '--listen-address=$ROUTER_IP'"
    check 'NetworkManager shared nftables table exists' nft list table ip \
      "nm-shared-${LAN_IF}"
    check 'NetworkManager installed IPv4 masquerading for downstream' sh -c \
      "nft list table ip 'nm-shared-$LAN_IF' | grep -F 'ip saddr $router_network' | grep -Fq masquerade"
    check 'eth0 has no global IPv6 address' sh -c \
      "! ip -6 -o address show dev '$LAN_IF' scope global | grep -q ."
  else
    warn "router mode is selected but $LAN_IF has no active downstream carrier"
    check 'offline router intent has an active isolation watcher' systemctl is-active --quiet \
      "$ARM_SERVICE"
    check 'offline router intent cannot autoconnect DHCP sharing' test \
      "$(nmcli -g connection.autoconnect connection show "$ROUTER_CONNECTION")" = no
  fi

  if [ "$failures" -ne 0 ]; then
    printf 'RESULT: %s invariant(s) failed\n' "$failures"
    return 1
  fi
  printf 'RESULT: all applicable invariants passed\n'
}

main() {
  case "${1:-}" in
    status)
      require_root
      preflight
      show_status
      ;;
    verify)
      require_root
      preflight
      verify
      ;;
    arm)
      require_root
      preflight
      arm
      ;;
    cancel-arm)
      require_root
      require_command systemctl
      systemctl stop "$ARM_SERVICE" 2>/dev/null || true
      recovery_preflight
      cancel_arm
      ;;
    lan-client)
      require_root
      require_command systemctl
      systemctl stop "$ARM_SERVICE" 2>/dev/null || true
      recovery_preflight
      snapshot_state || warn "could not save a pre-transition snapshot; continuing fail-closed"
      apply_client_mode yes
      ;;
    wifi-router)
      require_root
      preflight
      [ "${2:-}" = --confirm-isolated ] ||
        die "use 'arm', or pass --confirm-isolated after physically unplugging eth0"
      ensure_wifi_upstream
      snapshot_state
      select_router_mode
      activate_router_after_reconnect
      ;;
    apply-saved)
      require_root
      recovery_preflight
      apply_saved_mode
      ;;
    install-safe)
      require_root
      preflight
      apply_client_mode yes
      ;;
    arm-wait)
      require_root
      arm_wait
      ;;
    firewall-apply)
      require_root
      require_command nft
      firewall_apply
      ;;
    firewall-remove)
      require_root
      require_command nft
      firewall_remove
      ;;
    vnc-enable)
      require_root
      enable_vnc_after_desktop
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

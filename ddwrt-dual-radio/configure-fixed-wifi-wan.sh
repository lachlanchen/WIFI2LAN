#!/bin/sh
# Explicit DD-WRT mode switch for a dual-radio Broadcom router.
# No polling loop or automatic cable detection is installed.
set -eu

usage() {
    cat <<'EOF'
Usage:
  configure-fixed-wifi-wan.sh wifi [UPSTREAM_SSID] [RADIO] [WIRED_WAN_IF]
  configure-fixed-wifi-wan.sh wired [RADIO] [WIRED_WAN_IF]
  configure-fixed-wifi-wan.sh status [RADIO] [WIRED_WAN_IF]

Defaults: RADIO=wl0 and WIRED_WAN_IF=vlan2.

The wifi action assumes an open upstream network. It stores the upstream SSID
in router NVRAM so a later `wifi` invocation may omit it. The wired action
returns the selected radio to its original local-AP role.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

nvget() {
    nvram get "$1" 2>/dev/null || true
}

setnv() {
    nvram set "$1=$2"
}

remove_word() {
    remove="$1"
    shift
    result=""
    for word in "$@"; do
        [ "$word" = "$remove" ] && continue
        result="${result}${result:+ }${word}"
    done
    printf '%s\n' "$result"
}

add_word() {
    add="$1"
    shift
    result=""
    found=0
    for word in "$@"; do
        [ "$word" = "$add" ] && found=1
        result="${result}${result:+ }${word}"
    done
    [ "$found" -eq 1 ] || result="${result}${result:+ }${add}"
    printf '%s\n' "$result"
}

free_nvram() {
    nvram show 2>&1 >/dev/null |
        sed -n 's/.*(\([0-9][0-9]*\) left).*/\1/p' |
        tail -n 1
}

validate_router() {
    command -v nvram >/dev/null 2>&1 || die "nvram is unavailable"
    command -v wl >/dev/null 2>&1 || die "Broadcom wl is unavailable"
    [ -n "$(nvget DD_BOARD)" ] || die "DD-WRT board identity is unavailable"
    [ -n "$(nvget "${radio}_ifname")" ] || die "$radio has no interface"
    other=wl1
    [ "$radio" = wl1 ] && other=wl0
    [ -n "$(nvget "${other}_ifname")" ] ||
        die "a second radio is required to preserve a dedicated local AP"
}

copy_ap_to_vap() {
    for key in ssid net_mode closed security_mode akm crypto wpa_psk auth \
        auth_mode authmode wep wpa_gtk_rekey ap_isolate maxassoc; do
        setnv "${vap}_${key}" "$(nvget "${radio}_${key}")"
    done
    setnv "${vap}_mode" ap
    setnv "${vap}_ifname" "$vap"
    setnv "${vap}_bss_enabled" 1
    setnv "${vap}_bridged" 1
    setnv "${vap}_bridge" br0
    setnv "${vap}_ipaddr" 0.0.0.0
    setnv "${vap}_netmask" 0.0.0.0
}

copy_vap_to_ap() {
    [ -n "$(nvget "${vap}_ssid")" ] || return 0
    for key in ssid net_mode closed security_mode akm crypto wpa_psk auth \
        auth_mode authmode wep wpa_gtk_rekey ap_isolate maxassoc; do
        setnv "${radio}_${key}" "$(nvget "${vap}_${key}")"
    done
    setnv "${radio}_mode" ap
    setnv "${radio}_bridged" 1
    setnv "${radio}_bridge" br0
}

set_wan() {
    iface="$1"
    mac="$2"
    for key in wan_iface wan_ifname wan_ifname2 wan_ifnames; do
        setnv "$key" "$iface"
    done
    setnv wan_hwaddr "$mac"
    setnv wan_proto dhcp
}

remove_hook() {
    var="$1"
    marker="$2"
    setnv "$var" "$(nvget "$var" | sed "/# $marker$/d")"
}

append_hook() {
    var="$1"
    marker="$2"
    hook="$3"
    old="$(nvget "$var")"
    clean="$(printf '%s\n' "$old" | sed "/# $marker$/d")"
    if [ -n "$clean" ]; then
        setnv "$var" "$clean
$hook"
    else
        setnv "$var" "$hook"
    fi
}

prepend_hook() {
    var="$1"
    marker="$2"
    hook="$3"
    old="$(nvget "$var")"
    clean="$(printf '%s\n' "$old" | sed "/# $marker$/d")"
    if [ -n "$clean" ]; then
        setnv "$var" "$hook
$clean"
    else
        setnv "$var" "$hook"
    fi
}

install_fixed_hooks() {
    # DD-WRT may relabel wan_iface during APSTA startup. Correct it once after
    # boot, recreate DD-WRT's DHCP callback, renew on the station interface,
    # start the optional companion, then restore client NAT. The bounded boot
    # task exits; no daemon is left polling the router.
    startup_hook='(sleep 30;R="$(nvram get fwifi_radio)";[ -n "$R" ]||R=wl0;W="$(nvram get "${R}_ifname")";M="$(nvram get "${R}_hwaddr")";for K in wan_iface wan_ifname wan_ifname2 wan_ifnames;do nvram set "$K=$W";done;nvram set "wan_hwaddr=$M";ln -sf /sbin/rc /tmp/dhcpc;killall udhcpc >/dev/null 2>&1||true;ip -4 addr flush dev "$W";ip route del default >/dev/null 2>&1||true;udhcpc -i "$W" -p /var/run/udhcpc.pid -s /tmp/dhcpc >/tmp/fwifi-dhcp.log 2>&1&N=0;while [ "$N" -lt 15 ]&&! ip route|grep -q "^default .* dev $W";do sleep 2;N=$((N+1));done;restart firewall >/dev/null 2>&1||true;A=/tmp/astrill-lazy/alctl;if [ -x "$A" ];then "$A" start >/dev/null 2>&1||true;"$A" ensure >/dev/null 2>&1||true;"$A" start >/dev/null 2>&1||true;fi;for K in wan_iface wan_ifname wan_ifname2 wan_ifnames;do nvram set "$K=$W";done;nvram set "wan_hwaddr=$M";L="$(nvram get lan_ipaddr)/$(nvram get lan_netmask)";iptables -t nat -C POSTROUTING -s "$L" -o "$W" -j MASQUERADE 2>/dev/null||iptables -t nat -A POSTROUTING -s "$L" -o "$W" -j MASQUERADE) # ddwrt-fixed-wifi'
    firewall_hook='R="$(nvram get fwifi_radio)";[ -n "$R" ]||R=wl0;W="$(nvram get "${R}_ifname")";L="$(nvram get lan_ipaddr)/$(nvram get lan_netmask)";iptables -t nat -C POSTROUTING -s "$L" -o "$W" -j MASQUERADE 2>/dev/null||iptables -t nat -A POSTROUTING -s "$L" -o "$W" -j MASQUERADE # ddwrt-fixed-wifi'
    prepend_hook rc_startup ddwrt-fixed-wifi "$startup_hook"
    append_hook rc_firewall ddwrt-fixed-wifi "$firewall_hook"
    remove_hook rc_startup ddwrt-dual-uplink
}

clear_old_state() {
    for key in du_up_b64 du_up_md5 du_up_wifi du_up_wired du_up_wmac \
        du_up_emac du_up_port; do
        nvram unset "$key"
    done
}

action="${1:-}"
case "$action" in
    wifi)
        upstream_ssid="${2:-}"
        radio="${3:-wl0}"
        wired_if="${4:-vlan2}"
        vap="${radio}.1"
        validate_router
        [ -n "$upstream_ssid" ] || upstream_ssid="$(nvget fwifi_ssid)"
        [ -n "$upstream_ssid" ] || die "UPSTREAM_SSID is required the first time"

        wifi_if="$(nvget "${radio}_ifname")"
        wifi_mac="$(nvget "${radio}_hwaddr")"
        wired_mac="$(nvget fwifi_wired_mac)"
        if [ -z "$wired_mac" ] && [ -r "/sys/class/net/$wired_if/address" ]; then
            wired_mac="$(cat "/sys/class/net/$wired_if/address")"
        fi
        [ -n "$wired_mac" ] || wired_mac="$(nvget def_hwaddr)"
        [ -n "$wifi_mac" ] || die "wireless MAC is unavailable"
        [ -n "$wired_mac" ] || die "wired WAN MAC is unavailable"

        [ "$(nvget "${radio}_mode")" = apsta ] || copy_ap_to_vap
        setnv "${radio}_vifs" "$vap"
        setnv "${radio}_mode" apsta
        setnv "${radio}_ssid" "$upstream_ssid"
        setnv "${radio}_bridged" 0
        setnv "${radio}_bridge" ""
        setnv "${radio}_channel" 0
        setnv "${radio}_closed" 0
        setnv "${radio}_security_mode" disabled
        setnv "${radio}_akm" disabled
        setnv "${radio}_crypto" off
        setnv "${radio}_auth" 0
        setnv "${radio}_auth_mode" none
        setnv "${radio}_authmode" open
        setnv "${radio}_wep" disabled

        lan_words="$(nvget lan_ifnames)"
        lan_words="$(remove_word "$wifi_if" $lan_words)"
        lan_words="$(add_word "$vap" $lan_words)"
        setnv lan_ifnames "$lan_words"
        setnv fwifi_ssid "$upstream_ssid"
        setnv fwifi_radio "$radio"
        setnv fwifi_wired_mac "$wired_mac"
        set_wan "$wifi_if" "$wifi_mac"
        setnv pppoe_ifname ""
        install_fixed_hooks
        clear_old_state
        nvram commit
        echo "Configured fixed Wi-Fi WAN on $wifi_if. Reboot is required."
        ;;
    wired)
        radio="${2:-wl0}"
        wired_if="${3:-vlan2}"
        vap="${radio}.1"
        validate_router
        wifi_if="$(nvget "${radio}_ifname")"
        wired_mac="$(nvget fwifi_wired_mac)"
        if [ -z "$wired_mac" ] && [ -r "/sys/class/net/$wired_if/address" ]; then
            wired_mac="$(cat "/sys/class/net/$wired_if/address")"
        fi
        [ -n "$wired_mac" ] || wired_mac="$(nvget def_hwaddr)"
        [ -n "$wired_mac" ] || die "wired WAN MAC is unavailable"

        copy_vap_to_ap
        setnv "${radio}_vifs" ""
        lan_words="$(nvget lan_ifnames)"
        lan_words="$(remove_word "$vap" $lan_words)"
        lan_words="$(add_word "$wifi_if" $lan_words)"
        setnv lan_ifnames "$lan_words"
        set_wan "$wired_if" "$wired_mac"
        setnv pppoe_ifname "$wired_if"
        remove_hook rc_startup ddwrt-fixed-wifi
        remove_hook rc_firewall ddwrt-fixed-wifi
        remove_hook rc_startup ddwrt-dual-uplink
        clear_old_state
        nvram commit
        echo "Configured native wired WAN on $wired_if. Reboot is required."
        ;;
    status)
        radio="${2:-wl0}"
        wired_if="${3:-vlan2}"
        vap="${radio}.1"
        validate_router
        echo "board=$(nvget DD_BOARD)"
        echo "configured_wan=$(nvget wan_iface)"
        echo "default_route=$(ip route | sed -n '/^default /p' | head -n 1)"
        echo "radio_mode=$(nvget "${radio}_mode")"
        echo "radio_interface=$(nvget "${radio}_ifname")"
        echo "radio_mac=$(nvget "${radio}_hwaddr")"
        echo "second_radio_mac=$(nvget "${other}_hwaddr")"
        echo "virtual_ap=$(nvget "${vap}_ssid")"
        echo "second_ap=$(nvget wl1_ssid)"
        echo "startup_hook=$(nvget rc_startup | grep -c '# ddwrt-fixed-wifi$' || true)"
        echo "firewall_hook=$(nvget rc_firewall | grep -c '# ddwrt-fixed-wifi$' || true)"
        radio_if="$(nvget "${radio}_ifname")"
        echo "radio_associated=$(wl -i "$radio_if" status 2>/dev/null | grep -c '^SSID:' || true)"
        echo "wan_ipv4=$(ip -4 addr show dev "$radio_if" 2>/dev/null | sed -n 's/^[[:space:]]*inet \([^ ]*\).*/\1/p' | head -n 1)"
        echo "dhcp_client=$(ps | grep "[u]dhcpc -i $radio_if " | wc -l)"
        echo "wifi_nat=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -c " $radio_if " || true)"
        echo "nvram_free=$(free_nvram)"
        ;;
    *)
        usage
        exit 2
        ;;
esac

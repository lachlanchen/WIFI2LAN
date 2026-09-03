#!/bin/sh
set -eu

SSID="${1:-}"
LAN_ADDRESS="${2:-192.168.8.1}"
UPLINK_MAC="${3:-}"
BACKUP_DIR="/root/wifi-to-lan-backup-original"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

assert_uci() {
    key="$1"
    expected="$2"
    actual="$(uci -q get "$key" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] ||
        die "UCI verification failed for $key (expected '$expected', got '$actual')"
}

board="$(cat /tmp/sysinfo/board_name 2>/dev/null || true)"
[ "$board" = "tl-wr802n-v1" ] ||
    die "this script only supports OpenWrt on TL-WR802N v1"

[ -n "$SSID" ] || die "upstream SSID is required as the first argument"
[ "$LAN_ADDRESS" = "192.168.8.1" ] || die "LAN address must be 192.168.8.1"
if [ -n "$UPLINK_MAC" ]; then
    echo "$UPLINK_MAC" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' ||
        die "invalid optional uplink MAC address"
    UPLINK_MAC="$(echo "$UPLINK_MAC" | tr '[:lower:]' '[:upper:]')"
fi

wan_zone="$(uci -q get firewall.@zone[1].name 2>/dev/null || true)"
[ "$wan_zone" = "wan" ] || die "firewall zone 1 is not the untrusted WAN zone"

if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/config/system /etc/config/network /etc/config/wireless \
        /etc/config/firewall /etc/config/dhcp "$BACKUP_DIR/"
fi

uci -q batch <<EOF
set system.@system[0].hostname='wr802n-wifi-to-lan'

set network.lan='interface'
set network.lan.ifname='eth0'
set network.lan.proto='static'
set network.lan.ipaddr='$LAN_ADDRESS'
set network.lan.netmask='255.255.255.0'
delete network.lan.ip6assign

set network.wwan='interface'
set network.wwan.proto='dhcp'

set network.wwan6='interface'
set network.wwan6.proto='dhcpv6'
set network.wwan6.ifname='@wwan'
set network.wwan6.reqaddress='try'
set network.wwan6.reqprefix='no'
set network.wwan6.delegate='0'

set wireless.radio0.disabled='0'
set wireless.radio0.country='CN'
set wireless.radio0.channel='auto'
delete wireless.default_radio0
set wireless.uplink='wifi-iface'
set wireless.uplink.device='radio0'
set wireless.uplink.mode='sta'
set wireless.uplink.network='wwan'
set wireless.uplink.ssid='$SSID'
set wireless.uplink.encryption='none'

delete firewall.@zone[1].network
add_list firewall.@zone[1].network='wan'
add_list firewall.@zone[1].network='wan6'
add_list firewall.@zone[1].network='wwan'
add_list firewall.@zone[1].network='wwan6'
set firewall.@zone[1].input='REJECT'
set firewall.@zone[1].output='ACCEPT'
set firewall.@zone[1].forward='REJECT'
set firewall.@zone[1].masq='1'

set dhcp.lan.ignore='0'
set dhcp.lan.start='100'
set dhcp.lan.limit='100'
set dhcp.lan.leasetime='12h'
set dhcp.lan.ra='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.lan.ndp='disabled'
EOF

if [ -n "$UPLINK_MAC" ]; then
    uci set "wireless.uplink.macaddr=$UPLINK_MAC"
else
    uci -q delete wireless.uplink.macaddr || true
fi

assert_uci network.lan.ifname eth0
assert_uci network.lan.proto static
assert_uci network.lan.ipaddr 192.168.8.1
assert_uci network.wwan.proto dhcp
assert_uci network.wwan6.proto dhcpv6
assert_uci network.wwan6.delegate 0
assert_uci wireless.uplink.mode sta
assert_uci wireless.uplink.network wwan
assert_uci wireless.uplink.ssid "$SSID"
assert_uci wireless.uplink.encryption none
if [ -n "$UPLINK_MAC" ]; then
    assert_uci wireless.uplink.macaddr "$UPLINK_MAC"
fi
assert_uci 'firewall.@zone[1].name' wan
assert_uci 'firewall.@zone[1].network' 'wan wan6 wwan wwan6'
assert_uci 'firewall.@zone[1].input' REJECT
assert_uci 'firewall.@zone[1].forward' REJECT
assert_uci 'firewall.@zone[1].masq' 1
assert_uci dhcp.lan.ignore 0

uci commit system
uci commit network
uci commit wireless
uci commit firewall
uci commit dhcp

cat >/etc/sysctl.d/99-wifi-to-lan.conf <<'EOF'
# Route/NAT IPv4, but keep IPv6 local to the WR802N itself.
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
EOF

cat >/etc/hotplug.d/iface/99-ipv6-client-only <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
sysctl -q -w net.ipv6.conf.all.forwarding=0
sysctl -q -w net.ipv6.conf.default.forwarding=0
EOF
chmod 0755 /etc/hotplug.d/iface/99-ipv6-client-only
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv6.conf.all.forwarding=0
sysctl -q -w net.ipv6.conf.default.forwarding=0

echo "Configuration committed. The LAN address will become $LAN_ADDRESS."
echo "Reconnect by DHCP after the network restart, then verify with:"
echo "  ifstatus wwan"
echo "  ifstatus wwan6"
echo "  iptables -t nat -S"
echo "  logread | tail -n 100"

/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
/etc/init.d/network restart

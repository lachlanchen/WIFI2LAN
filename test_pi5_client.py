import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
INSTALLER = ROOT / "pi5-client" / "install-pi5-wifi-to-lan.sh"
RESET = ROOT / "pi5-client" / "reset-to-standard-network.sh"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_pi5_shell_scripts_parse():
    bash = shutil.which("bash")
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    if os.name == "nt" and git_bash.exists():
        bash = str(git_bash)
    if bash is None:
        return
    for script in (INSTALLER, RESET):
        subprocess.run(
            [bash, "-n", script.relative_to(ROOT).as_posix()],
            cwd=ROOT,
            check=True,
        )


def test_installer_uses_one_persistent_networkmanager_shared_profile():
    source = text(INSTALLER)
    assert 'LAN_CIDR="${LAN_CIDR:-192.168.23.1/24}"' in source
    assert 'ROUTER_CONNECTION="${ROUTER_CONNECTION:-wifi-to-lan}"' in source
    assert "ipv4.method shared" in source
    assert "ipv4.never-default yes" in source
    assert "ipv6.method disabled" in source
    assert "connection.autoconnect yes" in source
    assert "connection.autoconnect-priority 999" in source


def test_installer_preserves_active_wifi_as_dual_stack_client():
    source = text(INSTALLER)
    assert 'wifi_connection="$(nmcli -g GENERAL.CONNECTION device show "$WAN_IF")"' in source
    assert "802-11-wireless.powersave 2" in source
    assert "connection.autoconnect-retries 0" in source
    assert "802-11-wireless.cloned-mac-address permanent" in source
    assert '802-11-wireless.bssid "$WIFI_BSSID"' in source
    assert "ipv4.method auto" in source
    assert "ipv6.method auto" in source
    for forbidden in ("wifi-sec.psk", "psk=", "password123"):
        assert forbidden not in source


def test_installer_does_not_activate_dhcp_on_an_existing_lan():
    source = text(INSTALLER)
    assert 'cat "/sys/class/net/$LAN_IF/carrier"' in source
    assert 'ACTIVATE_CONNECTED="${ACTIVATE_CONNECTED:-0}"' in source
    assert '[ "$ACTIVATE_CONNECTED" = 1 ]' in source
    assert 'nmcli --wait 30 connection up "$ROUTER_CONNECTION"' in source
    assert "Move $LAN_IF from the existing LAN" in source


def test_installer_migrates_legacy_static_router_with_backup():
    source = text(INSTALLER)
    assert 'MIGRATE_LEGACY="${MIGRATE_LEGACY:-1}"' in source
    assert 'backup_path "$old_script" "$backup"' in source
    assert 'backup_path "$old_bridge_script" "$backup"' in source
    assert 'systemctl disable --now "$bridge_start_service" "$bridge_stop_service"' in source
    assert 'backup_path "$interfaces_file" "$backup"' in source
    assert 'backup_path "$dnsmasq_file" "$backup"' in source
    assert 'systemctl disable --now dnsmasq.service' in source
    assert 'nmcli device set "$LAN_IF" managed yes' in source
    assert "systemctl restart NetworkManager.service" in source
    assert 'GENERAL.NM-MANAGED device show "$LAN_IF"' in source
    assert 'delete_iptables_rule nat POSTROUTING' in source


def test_reset_snapshots_then_restores_ordinary_dhcp():
    source = text(RESET)
    snapshot_at = source.index("snapshot\n")
    delete_at = source.index('nmcli connection delete "$ROUTER_CONNECTION"')
    assert snapshot_at < delete_at
    assert "ipv4.method auto" in source
    assert "ipv6.method auto" in source
    assert 'nmcli --wait 30 connection up "$CLIENT_CONNECTION"' in source
    assert "system-connections.tar.gz" in source


def test_reset_does_not_change_wifi_ssh_or_vnc_configuration():
    source = text(RESET)
    assert "wifi-sec" not in source
    assert "sshd_config" not in source
    assert "wayvnc" not in source
    assert "raspi-config" not in source

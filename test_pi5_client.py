import os
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MODE = ROOT / "pi5-client" / "pi5-network-mode.sh"
INSTALLER = ROOT / "pi5-client" / "install-pi5-wifi-to-lan.sh"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_pi5_shell_scripts_parse():
    bash = shutil.which("bash")
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    if os.name == "nt" and git_bash.exists():
        bash = str(git_bash)
    if bash is None:
        return
    for script in (MODE, INSTALLER):
        subprocess.run(
            [bash, "-n", script.relative_to(ROOT).as_posix()],
            cwd=ROOT,
            check=True,
        )


def test_install_defaults_to_non_sharing_lan_client():
    source = text(INSTALLER)
    assert re.search(
        r'ROUTER_CONNECTION.*?connection\.autoconnect no.*?ipv4\.method shared',
        source,
        re.S,
    )
    assert '"$INSTALL_PATH" install-safe' in source
    assert 'systemctl disable --now dnsmasq.service' in source
    assert "mode_temporary=" in source
    assert 'mv -f "$mode_temporary" "${STATE_DIR}/mode"' in source
    assert "connection.autoconnect-priority 1000" not in source
    assert source.count("connection.autoconnect-priority 999") == 3


def test_router_profile_is_ipv4_only_and_uses_preserved_subnet():
    source = text(INSTALLER)
    assert 'ROUTER_CIDR="${ROUTER_CIDR:-192.168.2.1/24}"' in source
    assert "ipv4.method shared" in source
    assert "ipv6.method disabled" in source


def test_wifi_is_open_dual_stack_client_without_repo_credentials():
    source = text(INSTALLER)
    assert 'EXPECTED_SSID="${EXPECTED_SSID:-tsinghua}"' in source
    assert re.search(r'UPSTREAM_CONNECTION.*?ipv4\.method auto.*?ipv6\.method auto', source, re.S)
    combined = text(INSTALLER) + text(MODE)
    for forbidden in ("wifi-sec.psk", "psk=", "mdmd", "lazying.art"):
        assert forbidden not in combined


def test_router_activation_has_physical_and_explicit_guards():
    source = text(MODE)
    assert 'while [ "$down_count" -lt 5 ]' in source
    assert '"$(carrier_value)" = 0' in source
    assert "--confirm-isolated" in source
    assert 'systemctl start --no-block "$ARM_SERVICE"' in source
    assert "assert_router_subnet_not_on_wifi" in source
    assert "cidr_overlaps" in source


def test_cancel_and_emergency_client_transition_fail_closed():
    source = text(MODE)
    cancel_body = re.search(r"cancel_arm\(\) \{(.*?)\n\}", source, re.S).group(1)
    assert "apply_client_mode yes" in cancel_body
    main_body = source[source.index("main() {") :]
    lan_client_case = re.search(r"lan-client\)(.*?);;", main_body, re.S).group(1)
    assert "snapshot_state || warn" in lan_client_case
    assert "apply_client_mode yes" in lan_client_case


def test_recovery_does_not_depend_on_wifi_router_or_firewall_preflight():
    source = text(MODE)
    recovery = re.search(r"recovery_preflight\(\) \{(.*?)\n\}", source, re.S).group(1)
    assert "nft" not in recovery
    assert "UPSTREAM_CONNECTION" not in recovery
    main_body = source[source.index("main() {") :]
    apply_saved = re.search(r"apply-saved\)(.*?);;", main_body, re.S).group(1)
    assert "recovery_preflight" in apply_saved
    assert "\n      preflight\n" not in apply_saved


def test_strict_preflight_validates_exact_owned_profiles():
    source = text(MODE)
    strict = re.search(r"\npreflight\(\) \{(.*?)\n\}", source, re.S).group(1)
    for required in (
        '"$CLIENT_CONNECTION" ipv4.method auto',
        '"$CLIENT_CONNECTION" ipv6.method auto',
        '"$ROUTER_CONNECTION" ipv4.addresses "$ROUTER_CIDR"',
        '"$ROUTER_CONNECTION" ipv6.method disabled',
        '"$UPSTREAM_CONNECTION" ipv4.method auto',
        '"$UPSTREAM_CONNECTION" ipv6.method auto',
    ):
        assert required in strict


def test_rebooted_router_intent_rearms_instead_of_starting_dhcp():
    source = text(MODE)
    saved = re.search(r"apply_saved_mode\(\) \{(.*?)\n\}", source, re.S).group(1)
    assert "apply_client_mode yes no" in saved
    assert 'systemctl start --no-block "$ARM_SERVICE"' in saved
    assert 'connection up "$ROUTER_CONNECTION"' not in saved
    activation = re.search(r"activate_router_after_reconnect\(\) \{(.*?)\n\}", source, re.S).group(1)
    assert 'while [ "$(carrier_value)" != 1 ]' in activation
    assert 'connection up "$ROUTER_CONNECTION"' in activation
    assert activation.count('connection.autoconnect no') >= 2


def test_management_ports_are_blocked_only_on_wifi():
    source = text(MODE)
    assert 'iifname "${WAN_IF}" tcp dport { 22, 5900 }' in source
    assert 'iifname "${LAN_IF}"' not in source
    assert "flush ruleset" not in source
    installer = text(INSTALLER)
    assert "Requires=${PROGRAM_NAME}-management-guard.service" in installer
    assert "NM_DISPATCHER" in installer
    main_source = installer[installer.index("main() {") :]
    assert main_source.index('systemctl enable --now "${PROGRAM_NAME}-management-guard.service"') < main_source.index(
        "enable_remote_access"
    )


def test_shared_mode_checks_firewall_dhcp_and_nat():
    installer = text(INSTALLER)
    manager = text(MODE)
    assert "firewall-backend=none" in installer
    assert "firewall-backend=none" in manager
    assert "--listen-address=$ROUTER_IP" in manager
    assert "masquerade" in manager


def test_vnc_is_deferred_until_graphical_session():
    installer = text(INSTALLER)
    manager = text(MODE)
    assert "do_boot_behaviour B4" in installer
    assert "do_vnc 0" not in installer
    assert "ConditionPathExists=!${STATE_DIR}/vnc-enabled" in installer
    assert "find \"$runtime_dir\"" in manager
    assert "raspi-config nonint do_vnc 0" in manager


def test_package_download_is_only_a_missing_dependency_fallback():
    installer = text(INSTALLER)
    assert "install_missing_packages" in installer
    assert 'if [ "${#packages[@]}" -eq 0 ]' in installer
    assert "apt-get update ||" in installer

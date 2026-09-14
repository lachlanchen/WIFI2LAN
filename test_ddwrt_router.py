"""Run the router mode script against isolated fake DD-WRT commands."""

import json
import os
from pathlib import Path
import subprocess

import pytest


SCRIPT = Path(__file__).parent / 'ddwrt-dual-radio/configure-fixed-wifi-wan.sh'


@pytest.fixture
def router(tmp_path):
    state = tmp_path / 'nvram.json'
    state.write_text(json.dumps({
        'DD_BOARD': 'Test dual radio',
        'wl0_ifname': 'eth1', 'wl1_ifname': 'eth2',
        'wl0_hwaddr': '02:00:00:00:00:01',
        'wl1_hwaddr': '02:00:00:00:00:02',
        'def_hwaddr': '02:00:00:00:00:03',
        'wl0_mode': 'ap', 'wl1_mode': 'ap',
        'wl0_nband': '2', 'wl1_nband': '2',
        'wl0_net_mode': 'mixed', 'wl1_net_mode': 'mixed',
        'wl0_ssid': 'local-2.4', 'wl1_ssid': 'local-5g',
        'wl0_vifs': 'wl0.2', 'lan_ifnames': 'vlan1 eth1 eth2 wl0.2',
        'rc_startup': 'echo keep-startup', 'rc_firewall': 'echo keep-firewall',
        'lan_ipaddr': '192.0.2.1', 'lan_netmask': '255.255.255.0',
    }))
    binary = tmp_path / 'bin'
    binary.mkdir()
    nvram = binary / 'nvram'
    nvram.write_text('''#!/usr/bin/python3
import json, os, pathlib, sys
path = pathlib.Path(os.environ['TEST_NVRAM'])
values = json.loads(path.read_text())
action = sys.argv[1]
if action == 'get':
    print(values.get(sys.argv[2], ''))
elif action == 'set':
    key, value = sys.argv[2].split('=', 1)
    values[key] = value
elif action == 'unset':
    values.pop(sys.argv[2], None)
elif action == 'commit':
    values['_commits'] = values.get('_commits', 0) + 1
elif action == 'show':
    print('size: 4096 bytes (24000 left)', file=sys.stderr)
else:
    sys.exit(2)
if action in ('set', 'unset', 'commit'):
    path.write_text(json.dumps(values))
''')
    wl = binary / 'wl'
    wl.write_text('''#!/bin/sh
case "$3" in
    band) echo b ;;
    chanspec) echo '1 (0x1001)' ;;
    status) echo 'SSID: "test"' ;;
esac
''')
    for command in (nvram, wl):
        command.chmod(0o755)
    # No real routes, firewall, or process enumeration is needed by status.
    for name in ('ip', 'iptables', 'ps'):
        command = binary / name
        command.write_text('#!/bin/sh\nexit 0\n')
        command.chmod(0o755)
    env = {**os.environ, 'PATH': f'{binary}:/usr/bin:/bin', 'TEST_NVRAM': str(state)}

    def invoke(*args):
        return subprocess.run(['sh', str(SCRIPT), *args], env=env,
                              capture_output=True, text=True, timeout=10)

    invoke.env = env
    return state, invoke


def test_preserve_unrelated_virtual_ap_and_hooks(router):
    state, invoke = router
    for _ in range(2):
        result = invoke('wifi', 'upstream', 'wl0')
        assert result.returncode == 0, result.stderr
    values = json.loads(state.read_text())
    assert values['wl0_vifs'].split() == ['wl0.2', 'wl0.1']
    assert 'wl0.2' in values['lan_ifnames'].split()
    assert values['rc_startup'].count('# ddwrt-fixed-wifi') == 1
    assert 'echo keep-startup' in values['rc_startup']
    assert values['wl0.1_ssid'] == 'local-2.4'
    result = invoke('wired', 'wl0')
    assert result.returncode == 0, result.stderr
    values = json.loads(state.read_text())
    assert values['wl0_vifs'] == 'wl0.2'
    assert values['wl0_ssid'] == 'local-2.4'
    assert 'wl0.2' in values['lan_ifnames'].split()
    assert values['rc_startup'] == 'echo keep-startup'
    assert values['rc_firewall'] == 'echo keep-firewall'


@pytest.mark.parametrize('action,args', [('wifi', ['upstream', 'wl1']), ('wired', ['wl1'])])
def test_wrong_radio_cannot_leave_previous_uplink_running(router, action, args):
    state, invoke = router
    assert invoke('wifi', 'upstream', 'wl0').returncode == 0
    before = state.read_bytes()
    result = invoke(action, *args)
    assert result.returncode != 0
    assert 'restore wired mode on wl0' in result.stderr
    assert state.read_bytes() == before


def test_status_uses_saved_radio_and_reports_real_band_without_writes(router):
    state, invoke = router
    assert invoke('wifi', 'upstream', 'wl1').returncode == 0
    before = state.read_bytes()
    result = invoke('status')
    assert result.returncode == 0, result.stderr
    assert 'radio_interface=eth2' in result.stdout
    assert 'second_radio_interface=eth1' in result.stdout
    assert 'second_radio_band=b' in result.stdout
    assert 'second_radio_chanspec=1 (0x1001)' in result.stdout
    assert state.read_bytes() == before


def test_status_keeps_configured_band_when_mini_wl_returns_no_band(router):
    state, invoke = router
    (state.parent / 'bin/wl').write_text('#!/bin/sh\nexit 0\n')
    before = state.read_bytes()
    result = invoke('status')
    assert result.returncode == 0, result.stderr
    assert 'second_radio_configured_nband=2' in result.stdout
    assert 'second_radio_configured_net_mode=mixed' in result.stdout
    assert 'second_radio_band=\n' in result.stdout
    assert state.read_bytes() == before


@pytest.mark.parametrize('args', [('wifi', 'upstream', 'wl2'), ('status', 'wl0', 'bad interface')])
def test_invalid_interfaces_fail_before_writes(router, args):
    state, invoke = router
    before = state.read_bytes()
    assert invoke(*args).returncode != 0
    assert state.read_bytes() == before


@pytest.mark.parametrize('args', [('wifi', 'upstream', 'wl0'), ('wired', 'wl0')])
def test_existing_unmanaged_virtual_ap_is_not_overwritten(router, args):
    state, invoke = router
    values = json.loads(state.read_text())
    values['wl0_vifs'] = 'wl0.1 wl0.2'
    values['wl0.1_ssid'] = 'existing-guest-network'
    state.write_text(json.dumps(values))
    before = state.read_bytes()
    result = invoke(*args)
    assert result.returncode != 0
    assert 'existing unmanaged virtual AP' in result.stderr
    assert state.read_bytes() == before


@pytest.mark.parametrize('radio', ['wl0', 'wl1'])
def test_firewall_recovery_reattaches_only_managed_virtual_ap(router, radio):
    state, invoke = router
    trace = state.parent / 'bridge-calls'
    brctl = state.parent / 'bin/brctl'
    brctl.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_BRIDGE_CALLS"\nexit 1\n')
    brctl.chmod(0o755)
    assert invoke('wifi', 'upstream', radio).returncode == 0
    values = json.loads(state.read_text())
    hook = values['rc_firewall']
    for _ in range(2):
        result = subprocess.run(['sh', '-eu', '-c', hook],
                                env={**invoke.env, 'TEST_BRIDGE_CALLS': str(trace)},
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, result.stderr
    assert trace.read_text().splitlines() == [f'addif br0 {radio}.1'] * 2
    assert 'brctl addif br0 "$R.1"' in values['rc_startup']

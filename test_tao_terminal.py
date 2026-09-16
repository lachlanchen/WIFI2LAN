import configparser
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import pytest


ROOT = Path(__file__).parent / 'ubuntu-client'


def test_terminal_launcher_isolates_child_not_dbus_terminal_server():
    launcher = (ROOT / 'terminal-tao').read_text()
    assert 'exec /usr/bin/gnome-terminal' in launcher
    assert '-- /usr/local/bin/tao-shell "$@"' in launcher
    shell = (ROOT / 'tao-shell').read_text()
    assert '/usr/local/bin/tao-run "$@"' in shell
    assert '--rcfile /usr/local/share/wifi2lan/tao.bashrc -i' in shell
    assert 'exit "$result"' in shell
    for name in ('terminal-tao', 'tao-shell', 'tao-run', 'tao.bashrc'):
        subprocess.run(['bash', '-n', str(ROOT / name)], check=True)


def test_tao_bashrc_keeps_user_aliases_and_identifies_route(tmp_path):
    (tmp_path / '.bashrc').write_text("alias preserved='printf preserved'\nPS1='user-prompt> '\n")
    result = subprocess.run([
        'bash', '--noprofile', '--norc', '-c',
        'source "$1"; alias preserved; printf "%s\\n" "$WIFI2LAN_NETWORK" "$PS1"',
        'bash', str(ROOT / 'tao.bashrc'),
    ], env={**os.environ, 'HOME': str(tmp_path)}, text=True, capture_output=True, check=True)
    assert 'alias preserved=' in result.stdout
    assert '\ntao\n' in result.stdout
    assert '[tao]' in result.stdout
    assert 'user-prompt> ' in result.stdout
    assert 'Terminal (Tao)' in result.stdout


@pytest.mark.skipif(os.geteuid() == 0, reason='tao-run requires a desktop user')
@pytest.mark.parametrize('exit_code', [0, 37])
def test_tao_run_restores_user_path_after_privilege_drop(tmp_path, exit_code):
    sudo = tmp_path / 'sudo'
    sudo.write_text('''#!/usr/bin/python3
import os, sys
args = sys.argv[1:]
if args == ['-n', '/usr/local/libexec/wifi2lan-app-network', 'tao']:
    sys.exit(0)
assert args[:4] == ['-n', '/usr/local/libexec/astrill-lazy-netns', 'launch', 'tao']
assert int(args[4]) == os.getuid()
assert args[6] == '/usr/bin/env'
print('simulated-host-launch', file=sys.stderr)
# Simulate the privileged helper's restricted environment after dropping UID.
os.execve(args[6], args[6:], {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'})
''')
    sudo.chmod(0o755)
    user_path = f'{tmp_path}:/custom path/bin:/usr/local/bin:/usr/bin:/bin'
    result = subprocess.run([
        '/bin/bash', str(ROOT / 'tao-run'), '/usr/bin/python3', '-c',
        'import json, os, sys; '
        'print(json.dumps([os.environ["PATH"], sys.argv[1:]])); '
        f'sys.exit({exit_code})', 'two words', 'literal;$HOME',
    ], env={**os.environ, 'PATH': user_path, 'WIFI2LAN_NETWORK': 'tao'},
       text=True, capture_output=True)
    assert result.returncode == exit_code, result.stderr
    assert 'simulated-host-launch' in result.stderr
    assert json.loads(result.stdout) == [user_path, ['two words', 'literal;$HOME']]


@pytest.mark.skipif(os.environ.get('WIFI2LAN_TEST_LIVE_TAO') != '1',
                    reason='opt-in: requires the installed, working Tao namespace')
@pytest.mark.parametrize('exit_code', [0, 37])
def test_nested_tao_run_reuses_real_namespace(exit_code):
    namespace_inode = Path('/run/netns/al-tao').stat().st_ino
    result = subprocess.run([
        '/usr/local/bin/tao-run', '/usr/bin/env', 'WIFI2LAN_NETWORK=not-tao',
        '/bin/bash', str(ROOT / 'tao-run'), '/usr/bin/python3', '-c',
        'import json, os, sys; '
        'print(json.dumps([os.stat("/proc/self/ns/net").st_ino, os.getuid(), sys.argv[1:]])); '
        f'sys.exit({exit_code})', 'two words', 'literal;$HOME',
    ], text=True, capture_output=True, timeout=60)
    assert result.returncode == exit_code, result.stderr
    assert 'already active; reusing current network' in result.stderr
    assert json.loads(result.stdout) == [namespace_inode, os.getuid(),
                                         ['two words', 'literal;$HOME']]


def test_desktop_has_distinct_icon_and_uses_launcher():
    desktop = configparser.ConfigParser(interpolation=None)
    desktop.read(ROOT / 'terminal-tao.desktop')
    entry = desktop['Desktop Entry']
    assert entry['Name'] == 'Terminal (Tao)'
    assert entry['Exec'] == '/usr/local/bin/terminal-tao'
    assert entry['Icon'] == 'terminal-tao'
    assert entry['Terminal'] == 'false'
    assert ET.parse(ROOT / 'terminal-tao.svg').getroot().get('viewBox') == '0 0 128 128'

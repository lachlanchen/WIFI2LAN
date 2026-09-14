#!/usr/bin/python3
"""Validate and prepare a router-specific network using Astrill Lazy's helper."""

import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


HELPER = '/usr/local/libexec/astrill-lazy-netns'
CONFIG = Path('/etc/wifi2lan-apps')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True,
                          timeout=45, **kwargs).stdout


def inspect(*args):
    return json.loads(run('/usr/sbin/ip', '-j', *args))


def validate_config(config):
    if set(config) != {'interface', 'mac', 'gateway'}:
        raise ValueError('profile must specify interface, mac, and gateway')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', config['interface']):
        raise ValueError('invalid interface name')
    if not re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', config['mac']):
        raise ValueError('invalid adapter MAC')
    ipaddress.IPv4Address(config['gateway'])


def validate_parent(config, parent):
    if len(parent) != 1 or parent[0].get('address') != config['mac']:
        raise ValueError('Tao adapter identity does not match; refusing another uplink')
    if 'LOWER_UP' not in parent[0].get('flags', []):
        raise ValueError('Tao Ethernet cable has no carrier')


def validate_link(parent, links):
    if len(links) != 1:
        raise ValueError('isolated Ethernet interface is missing')
    link = links[0]
    if (link.get('link_index') != parent[0]['ifindex'] or
            link.get('linkinfo', {}).get('info_kind') != 'macvlan'):
        raise ValueError('existing namespace uses another parent; refusing to reuse it')


def validate_network(config, addresses, routes):
    defaults = [route for route in routes if route.get('dst') == 'default']
    if (len(defaults) != 1 or defaults[0].get('gateway') != config['gateway'] or
            defaults[0].get('dev') != 'eth0'):
        raise ValueError('isolated network does not have the expected Tao gateway')
    networks = []
    for interface in addresses:
        for address in interface.get('addr_info', []):
            if address.get('family') == 'inet':
                networks.append(ipaddress.ip_interface(
                    f"{address['local']}/{address['prefixlen']}").network)
    if not any(ipaddress.ip_address(config['gateway']) in net for net in networks):
        raise ValueError('isolated DHCP address is not on the Tao LAN')
    for route in routes:
        if route.get('dst') != 'default' and (
                route.get('gateway') or route.get('dev') != 'eth0' or
                ipaddress.ip_network(route['dst']) not in networks):
            raise ValueError('unexpected additional route in app namespace')


def expected_dhcp(executable, arguments, pid_file):
    return (executable == '/usr/bin/busybox' and len(arguments) > 1 and
            arguments[1] == 'udhcpc' and '-p' in arguments and
            arguments[arguments.index('-p') + 1:arguments.index('-p') + 2] == [pid_file])


def renew_lease(profile, namespace):
    pid_file = Path(f'/run/astrill-lazy/{profile}.udhcpc.pid')
    pid = int(pid_file.read_text().strip())
    if pid <= 1:
        raise ValueError('invalid DHCP process ID')
    process = Path(f'/proc/{pid}')
    arguments = (process / 'cmdline').read_bytes().decode().rstrip('\0').split('\0')
    if (not expected_dhcp(os.readlink(process / 'exe'), arguments, str(pid_file)) or
            (process / 'ns/net').stat().st_ino != Path(f'/run/netns/{namespace}').stat().st_ino):
        raise ValueError('DHCP process identity does not match; refusing to signal it')
    # Renew in place: keep open apps and never touch the host's default route.
    os.kill(pid, signal.SIGUSR1)
    for _ in range(20):
        routes = inspect('-n', namespace, 'route', 'show')
        if any(route.get('dst') == 'default' for route in routes):
            return
        time.sleep(0.5)
    raise ValueError('Tao DHCP renewal did not restore its route; no fallback was used')


def prepare(profile):
    if not re.fullmatch(r'[a-z0-9]{1,10}', profile):
        raise ValueError('invalid profile name')
    path = CONFIG / f'{profile}.json'
    info = path.stat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('profile configuration must be root-owned and not writable by others')
    config = json.loads(path.read_text())
    validate_config(config)
    namespace = f'al-{profile}'
    parent = inspect('link', 'show', 'dev', config['interface'])
    validate_parent(config, parent)
    if any(item['name'] == namespace for item in inspect('netns', 'list')):
        # Do not let a stale profile name silently select another physical NIC.
        validate_link(parent, inspect('-d', '-n', namespace, 'link', 'show', 'eth0'))
    run(HELPER, 'prepare', profile, config['interface'],
        env={**os.environ, 'ASTRILL_LAZY_PROFILE_DNS': config['gateway']})
    run('/usr/sbin/ip', 'netns', 'exec', namespace, '/usr/sbin/sysctl', '-qw',
        'net.ipv6.conf.all.disable_ipv6=1', 'net.ipv6.conf.default.disable_ipv6=1')
    validate_link(parent, inspect('-d', '-n', namespace, 'link', 'show', 'eth0'))
    if not any(route.get('dst') == 'default' for route in
               inspect('-n', namespace, 'route', 'show')):
        renew_lease(profile, namespace)
    validate_network(config, inspect('-n', namespace, 'address', 'show', 'eth0'),
                     inspect('-n', namespace, 'route', 'show'))
    # DHCP renewals use the same gateway DNS override from the helper's environment.
    resolver = Path(f'/etc/netns/{namespace}/resolv.conf').read_text().splitlines()
    if resolver != [f"nameserver {config['gateway']}"]:
        raise ValueError('isolated DNS does not match the Tao router')
    print(f'{namespace}: ready via {config["gateway"]}', file=sys.stderr)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--validate-config':
        config = json.loads(Path(sys.argv[2]).read_text())
        validate_config(config)
        validate_parent(config, inspect('link', 'show', 'dev', config['interface']))
        return
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise ValueError('usage: sudo wifi2lan-app-network PROFILE')
    # Use a root-only directory, not a predictable file in shared /run/lock.
    state = Path('/run/wifi2lan-apps')
    state.mkdir(mode=0o700, exist_ok=True)
    info = state.stat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('unsafe runtime directory permissions')
    # Serialize prepare calls, but do not hold the lock for the app lifetime.
    with (state / 'prepare.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare(sys.argv[1])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'wifi2lan-app-network: {error}', file=sys.stderr)
        sys.exit(1)

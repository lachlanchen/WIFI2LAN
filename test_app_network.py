import importlib.util
from pathlib import Path

import pytest


spec = importlib.util.spec_from_file_location(
    'app_network', Path(__file__).parent / 'ubuntu-client/wifi2lan-app-network.py')
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)

CONFIG = {'interface': 'enx123', 'mac': '02:00:00:00:00:01', 'gateway': '192.0.2.1'}
PARENT = [{'ifindex': 92, 'address': CONFIG['mac'], 'flags': ['UP', 'LOWER_UP']}]
LINK = [{'link_index': 92, 'linkinfo': {'info_kind': 'macvlan'}}]
ADDRESSES = [{'addr_info': [{'family': 'inet', 'local': '192.0.2.17', 'prefixlen': 24}]}]
ROUTES = [{'dst': 'default', 'gateway': '192.0.2.1', 'dev': 'eth0'},
          {'dst': '192.0.2.0/24', 'dev': 'eth0'}]


def test_expected_isolated_network():
    network.validate_config(CONFIG)
    network.validate_parent(CONFIG, PARENT)
    network.validate_link(PARENT, LINK)
    network.validate_network(CONFIG, ADDRESSES, ROUTES)


@pytest.mark.parametrize('parent', [[], [{'address': '02:00:00:00:00:02'}],
                                     [{'address': CONFIG['mac'], 'flags': ['UP']} ]])
def test_wrong_adapter_or_no_carrier_refused(parent):
    with pytest.raises(ValueError):
        network.validate_parent(CONFIG, parent)


def test_namespace_parent_mismatch_refused():
    with pytest.raises(ValueError):
        network.validate_link([{'ifindex': 50}], LINK)


@pytest.mark.parametrize('routes', [[],
    [{'dst': 'default', 'gateway': '198.51.100.1', 'dev': 'eth0'}],
    ROUTES + [{'dst': '0.0.0.0/1', 'gateway': '192.0.2.2', 'dev': 'eth0'}],
    ROUTES + [{'dst': '198.51.100.0/24', 'dev': 'eth1'}],
])
def test_missing_or_unexpected_routes_refused(routes):
    with pytest.raises(ValueError):
        network.validate_network(CONFIG, ADDRESSES, routes)


def test_wrong_dhcp_network_refused():
    with pytest.raises(ValueError):
        network.validate_network(CONFIG, [], ROUTES)


@pytest.mark.parametrize('update', [{'interface': 'bad name'}, {'gateway': '::1'},
                                    {'mac': 'not-a-mac'}, {'extra': 'setting'}])
def test_invalid_config_refused(update):
    with pytest.raises(ValueError):
        network.validate_config({**CONFIG, **update})


@pytest.mark.parametrize('executable,args,expected', [
    ('/usr/bin/busybox', ['/usr/bin/busybox', 'udhcpc', '-p', '/run/tao.pid'], True),
    ('/usr/bin/busybox', ['/usr/bin/busybox', 'udhcpc', '-p', '/run/other.pid'], False),
    ('/usr/bin/busybox', ['/usr/bin/busybox', 'udhcpc', '-p'], False),
    ('/usr/bin/busybox', ['/usr/bin/busybox', 'sh', '-p', '/run/tao.pid'], False),
    ('/usr/bin/other', ['/usr/bin/busybox', 'udhcpc', '-p', '/run/tao.pid'], False),
])
def test_dhcp_signal_requires_exact_identity(executable, args, expected):
    assert network.expected_dhcp(executable, args, '/run/tao.pid') is expected

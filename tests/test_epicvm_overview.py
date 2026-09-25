import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'dashboard'))

import app as dashboard_app


def test_dashboard_overview_combines_real_host_inventory_and_activity(monkeypatch):
    monkeypatch.setattr(
        dashboard_app,
        '_get_system_stats',
        lambda: {
            'cpu': {'cores': 2, 'usage': 12.5},
            'memory': {'total': 100, 'used': 40, 'available': 60, 'percent': 40},
            'disk': [{'mountpoint': '/', 'total': 1000, 'used': 250, 'free': 750, 'percent': 25}],
            'network': {'rx_bytes': 10, 'tx_bytes': 20},
            'uptime': 123,
            'loadavg': [0.1],
        },
    )
    monkeypatch.setattr(dashboard_app, 'manager_json_list', lambda: [
        {'name': 'real-vm', 'status': 'blobevm_real-vm (running)', 'url': '/vm/real-vm/'},
    ])
    monkeypatch.setattr(dashboard_app, 'manager_json_fleet_list', lambda: [
        {'name': 'real-vm', 'status': 'blobevm_real-vm (running)', 'url': '/vm/real-vm/'},
    ])
    monkeypatch.setattr(
        dashboard_app.dash_optimizer,
        '_history_state',
        lambda: {'events': [{'action': 'start', 'vm': 'real-vm', 'ts': 1700000000}]},
    )
    monkeypatch.setattr(dashboard_app.dash_optimizer, 'status', lambda: (_ for _ in ()).throw(AssertionError('expensive optimizer status must not run')))
    monkeypatch.setattr(dashboard_app.platform, 'node', lambda: 'real-host')
    monkeypatch.setattr(dashboard_app, '_read_os_release', lambda: 'Real Linux')
    monkeypatch.setattr(dashboard_app, '_kernel_release', lambda: 'real-kernel')

    payload = dashboard_app._dashboard_overview_payload()

    assert payload['host']['hostname'] == 'real-host'
    assert payload['host']['os'] == 'Real Linux'
    assert payload['host']['kernel'] == 'real-kernel'
    assert payload['stats']['cpu']['usage'] == 12.5
    assert payload['instances'][0]['name'] == 'real-vm'
    assert payload['activity'][0]['vm'] == 'real-vm'


def test_dashboard_overview_does_not_fabricate_empty_activity(monkeypatch):
    monkeypatch.setattr(dashboard_app, '_get_system_stats', lambda: {})
    monkeypatch.setattr(dashboard_app, 'manager_json_list', lambda: [])
    monkeypatch.setattr(dashboard_app, 'manager_json_fleet_list', lambda: [])
    monkeypatch.setattr(dashboard_app.dash_optimizer, '_history_state', lambda: {'events': []})
    monkeypatch.setattr(dashboard_app.dash_optimizer, 'status', lambda: (_ for _ in ()).throw(AssertionError('expensive optimizer status must not run')))
    monkeypatch.setattr(dashboard_app.platform, 'node', lambda: 'real-host')
    monkeypatch.setattr(dashboard_app, '_read_os_release', lambda: 'Real Linux')
    monkeypatch.setattr(dashboard_app, '_kernel_release', lambda: 'real-kernel')

    payload = dashboard_app._dashboard_overview_payload()

    assert payload['instances'] == []
    assert payload['activity'] == []

"""Fixture-only regression for choosing a native Windows desktop in Management."""
from types import SimpleNamespace

from test_account_workspace import workspace, login, post


def test_management_desktop_assignment_requires_a_real_native_host(workspace, monkeypatch):
    catalogs = {'win-a': {'ok': True, 'apiVersion': 3, 'ready': True, 'seats': [], 'games': []},
                'win-b': {'ok': True, 'apiVersion': 3, 'ready': True, 'seats': [], 'games': []}}
    hosts = [SimpleNamespace(id='win-a', display_name='Windows A', platform='windows'),
             SimpleNamespace(id='win-b', display_name='Windows B', platform='windows')]

    class Registry:
        def public_records(self): return [vars(host) for host in hosts]

    monkeypatch.setattr(workspace, 'VM_HOST_REGISTRY', Registry())

    def host(host_id):
        if host_id not in catalogs:
            raise KeyError(host_id)
        return SimpleNamespace(host_name=host_id, client=SimpleNamespace(
            _request=lambda method, path, payload=None, **kw: catalogs[host_id]))

    monkeypatch.setattr(workspace, '_vm_host', host)
    admin, alice, bob = login(workspace, 'rootadmin', dashboard=True), login(workspace), login(workspace, 'bob')
    endpoint = '/EpicVM/api/management/host-gaming/desktops'
    assert alice.get(endpoint).status_code == 403
    listed = admin.get(endpoint)
    assert listed.status_code == 200
    assert {item['hostId'] for item in listed.json['desktops']} == {'win-a', 'win-b'}

    path = 'management/host-gaming/desktop-grants'
    assert post(alice, path, username='alice', hostId='win-a').status_code == 403
    assert post(admin, path, username='alice', hostId='missing').status_code == 400
    assert post(admin, path, username='nobody', hostId='win-a').status_code == 400
    assert post(admin, path, username='alice', hostId='win-a').status_code == 200
    assert post(admin, path, username='alice', hostId='win-a').status_code == 409
    assert post(admin, path, username='alice', hostId='win-b').status_code == 200
    assert post(admin, path, username='bob', hostId='win-a').status_code == 200

    with workspace._users_conn() as conn:
        assert {row['host_id'] for row in conn.execute(
            "SELECT host_id FROM host_desktop_grants WHERE username='alice'")} == {'win-a', 'win-b'}
    assert {item['hostId'] for item in alice.get('/EpicVM/api/account/host-gaming/desktops').json['desktops']} == {'win-a', 'win-b'}
    assert [item['hostId'] for item in bob.get('/EpicVM/api/account/host-gaming/desktops').json['desktops']] == ['win-a']

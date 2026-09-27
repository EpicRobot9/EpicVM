from types import SimpleNamespace
import hashlib
import json
import re

from dashboard.direct_stream_auth import verify_grant

from test_account_workspace import workspace, login, post


def test_host_game_grant_controls_native_launch(workspace, monkeypatch, tmp_path):
    calls = []

    def agent(method, path, payload=None, **kwargs):
        calls.append((method, path, payload))
        if path == '/v1/host-gaming':
            account = lambda owner: 'evseat_' + hashlib.sha256(owner.encode()).hexdigest()[:13]
            return {'ok': True, 'apiVersion': 3, 'ready': True,
                    'games': [{'id': 'harmless', 'title': 'Harmless', 'available': True}],
                    'seats': [{'id': 'alice-seat', 'accountName': account('portal:alice'), 'status': 'Ready', 'portBase': 48100},
                              {'id': 'bob-seat', 'accountName': 'EpicVM_bob', 'status': 'Ready', 'portBase': 48130}]}
        if path == '/v1/host-gaming/account-credential/reveal':
            return {'ok': True, 'accountName': 'evseat_test', 'password': 'test-only-password'}
        return {'ok': True, 'seatId': 'seat-1', 'portBase': 48100}

    class Stream:
        def quarantine_staged(self, name): return None
        def build_plan(self, **kwargs): return kwargs
        def stage_plan(self, plan): return None
        def start_staged(self, name): return None
        def pair_staged(self, name, *, pin_submitter): pin_submitter('1234')
        def has_auto_login(self, name): return True

    monkeypatch.setattr(workspace, '_console_orchestrator', lambda: Stream())
    monkeypatch.setattr(workspace, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=agent, base_url='http://100.72.220.117:8765/')))
    monkeypatch.setattr(workspace.VM_HOST_REGISTRY, 'public_records',
                        lambda: [{'id': 'epic-pc', 'platform': 'windows', 'display_name': 'Test host'}])
    alice = login(workspace)
    initial = alice.get('/EpicVM/api/account/host-gaming').json
    assert initial['games'] == []
    assert initial['seat'] == {'id': 'alice-seat', 'status': 'Ready', 'portBase': 48100, 'errorMessage': None}
    assert 'bob-seat' not in str(initial)
    assert post(alice, 'account/host-gaming/launch', gameId='harmless').status_code == 400
    admin = login(workspace, 'rootadmin', dashboard=True)
    assert post(admin, 'management/host-gaming/grants', username='alice', gameId='harmless').status_code == 200
    assert alice.get('/EpicVM/api/account/host-gaming').json['games'][0]['id'] == 'harmless'
    result = post(alice, 'account/host-gaming/launch', gameId='harmless')
    assert result.status_code == 200
    assert any(call[1] == '/v1/host-gaming/launch' and call[2] == {'owner': 'portal:alice', 'gameId': 'harmless'} for call in calls)
    assert any(call[1] == '/v1/host-gaming/pair' and call[2] == {'owner': 'portal:alice', 'pin': '1234'} for call in calls)
    assert result.json['launchUrl'].startswith('/EpicVM/stream-launch/seat-')
    seat_name = result.json['launchUrl'].strip('/').split('/')[-1]
    assert alice.get(result.json['launchUrl']).status_code == 503
    manifest = tmp_path / 'streams.json'
    key_file = tmp_path / 'key'
    key_file.write_bytes(b'a' * 32)
    manifest.write_text(json.dumps({seat_name: {
        'enabled': True, 'hostId': 'epic-pc', 'hostUrl': 'https://epicbriiiii.zapto.org',
        'streamPath': f'/EpicVM/{seat_name}/stream.html?hostId=123&appId=456'}}))
    monkeypatch.setenv('EPICVM_DIRECT_STREAMS_FILE', str(manifest))
    monkeypatch.setenv('EPICVM_DIRECT_STREAM_KEY_FILE', str(key_file))
    page = alice.get(result.json['launchUrl'])
    assert page.status_code == 200
    match = re.search(rb'name="grant" value="([^"]+)"', page.data)
    assert match
    grant = verify_grant(b'a' * 32, match.group(1).decode())
    assert grant['route'] == seat_name and grant['sub'] == 'portal:alice'
    assert login(workspace, 'bob').get(result.json['launchUrl']).status_code == 403
    assert alice.get('/dashboard/auth/vm/' + seat_name).status_code == 200
    assert login(workspace, 'bob').get('/dashboard/auth/vm/' + seat_name).status_code == 403
    assert post(alice, 'account/host-gaming/stop').status_code == 200
    assert calls[-1][2] == {'owner': 'portal:alice'}
    assert alice.get('/dashboard/auth/vm/' + seat_name).status_code == 403

    assert alice.get('/EpicVM/api/account/host-gaming').json['desktopAccess'] is False
    assert post(login(workspace, 'bob'), 'account/host-gaming/desktop').status_code == 400
    assert post(admin, 'management/host-gaming/desktop-grants', username='alice').status_code == 200
    assert alice.get('/EpicVM/api/account/host-gaming').json['desktopAccess'] is True
    assert post(alice, 'account/host-gaming/desktop').status_code == 200
    assert any(call[1] == '/v1/host-gaming/desktop' and call[2] == {'owner': 'portal:alice'} for call in calls)
    assert post(alice, 'management/host-gaming/account-credential/reveal', username='alice').status_code == 403
    revealed = post(admin, 'management/host-gaming/account-credential/reveal', username='alice')
    assert revealed.status_code == 200
    assert revealed.json['password'] == 'test-only-password'
    assert revealed.headers['Cache-Control'] == 'no-store'
    with workspace._users_conn() as conn:
        rows = conn.execute('SELECT actor_username, target_username FROM host_credential_reveals').fetchall()
    assert [(row['actor_username'], row['target_username']) for row in rows] == [('rootadmin', 'alice')]
    assert post(admin, 'management/host-gaming/desktop-grants', username='alice', enabled=False).status_code == 200
    assert alice.get('/EpicVM/api/account/host-gaming').json['desktopAccess'] is False


def test_host_game_admin_registration_and_csrf(workspace, monkeypatch):
    calls = []

    def agent(method, path, payload=None, **kwargs):
        calls.append((method, path, payload))
        return {'ok': True, 'apiVersion': 2, 'games': []}

    monkeypatch.setattr(workspace, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=agent)))
    alice = login(workspace)
    assert post(alice, 'management/host-gaming/games', id='harmless').status_code == 403
    admin = login(workspace, 'rootadmin', dashboard=True)
    assert admin.post('/EpicVM/api/management/host-gaming/games', json={'id': 'harmless'}).status_code == 403
    assert post(admin, 'management/host-gaming/games', id='harmless', title='Harmless', executable='C:\\Tools\\harmless.exe').status_code == 200
    assert calls[-1][1] == '/v1/host-gaming/games'
    assert post(admin, 'management/host-gaming/games/remove', gameId='harmless').status_code == 200
    assert calls[-1][1] == '/v1/host-gaming/games/remove'


def test_personal_desktop_list_and_entry_are_scoped_to_each_user_and_host(workspace, monkeypatch):
    calls = []
    active_seats = {}
    ports = {'win-a': 48100, 'win-b': 48130}

    def agent(host_id, method, path, payload=None, **kwargs):
        calls.append((host_id, method, path, payload))
        if method == 'GET' and path == '/v1/host-gaming':
            seats = []
            for owner, seat_id in active_seats.get(host_id, {}).items():
                username = owner.split(':', 1)[1]
                seats.append({'id': seat_id, 'accountName': 'EpicVM_' + username,
                              'status': 'Ready', 'portBase': ports[host_id]})
            return {'ok': True, 'apiVersion': 3, 'ready': True, 'games': [], 'seats': seats}
        if method == 'POST' and path == '/v1/host-gaming/desktop':
            owner = payload['owner']
            seat_id = host_id + '-' + owner.split(':', 1)[1]
            active_seats.setdefault(host_id, {})[owner] = seat_id
            return {'ok': True, 'seatId': seat_id, 'portBase': ports[host_id]}
        return {'ok': True}

    def host(host_id):
        client = SimpleNamespace(
            _request=lambda method, path, payload=None, **kwargs: agent(host_id, method, path, payload, **kwargs),
            base_url='http://100.72.220.117:8765/',
        )
        return SimpleNamespace(client=client)

    class Stream:
        def quarantine_staged(self, name): return None
        def build_plan(self, **kwargs): return kwargs
        def stage_plan(self, plan): return None
        def start_staged(self, name): return None
        def pair_staged(self, name, *, pin_submitter): pin_submitter('1234')
        def has_auto_login(self, name): return True

    monkeypatch.setattr(workspace, '_console_orchestrator', lambda: Stream())
    monkeypatch.setattr(workspace, '_vm_host', host)
    monkeypatch.setattr(workspace.VM_HOST_REGISTRY, 'public_records',
                        lambda: [{'id': host_id, 'platform': 'windows', 'display_name': host_id}
                                 for host_id in ('win-a', 'win-b')])
    admin = login(workspace, 'rootadmin', dashboard=True)
    for host_id in ('win-a', 'win-b'):
        assert post(admin, 'management/host-gaming/desktop-grants', username='alice', hostId=host_id).status_code == 200
    assert post(admin, 'management/host-gaming/desktop-grants', username='bob', hostId='win-b').status_code == 200

    alice, bob = login(workspace), login(workspace, 'bob')
    alice_initial = alice.get('/EpicVM/api/account/host-gaming/desktops')
    bob_initial = bob.get('/EpicVM/api/account/host-gaming/desktops')
    assert {item['hostId'] for item in alice_initial.json['desktops']} == {'win-a', 'win-b'}
    assert [item['hostId'] for item in bob_initial.json['desktops']] == ['win-b']

    bob_opened = post(bob, 'account/host-gaming/desktop', hostId='win-b')
    assert bob_opened.status_code == 200, bob_opened.data
    assert post(bob, 'account/host-gaming/desktop', hostId='win-a').status_code == 400
    assert post(alice, 'account/host-gaming/desktop', hostId='win-c').status_code == 400

    alice_a = post(alice, 'account/host-gaming/desktop', hostId='win-a')
    alice_b = post(alice, 'account/host-gaming/desktop', hostId='win-b')
    assert alice_a.status_code == 200, alice_a.data
    assert alice_b.status_code == 200, alice_b.data
    assert alice_a.json['launchUrl'] != alice_b.json['launchUrl']

    alice_desktops = alice.get('/EpicVM/api/account/host-gaming/desktops').json['desktops']
    bob_desktops = bob.get('/EpicVM/api/account/host-gaming/desktops').json['desktops']
    alice_by_host = {item['hostId']: item for item in alice_desktops}
    assert alice_by_host['win-a']['seat']['id'] == 'win-a-alice'
    assert alice_by_host['win-b']['seat']['id'] == 'win-b-alice'
    assert bob_desktops[0]['seat']['id'] == 'win-b-bob'
    assert 'win-b-bob' not in str(alice_desktops)
    assert 'win-a-alice' not in str(bob_desktops)
    assert ('win-a', 'POST', '/v1/host-gaming/desktop', {'owner': 'portal:alice'}) in calls
    assert ('win-b', 'POST', '/v1/host-gaming/desktop', {'owner': 'portal:alice'}) in calls
    assert not any(host_id == 'win-a' and path == '/v1/host-gaming/desktop' and payload == {'owner': 'portal:bob'}
                   for host_id, _, path, payload in calls)

from types import SimpleNamespace
from test_account_workspace import workspace, login, post


def host(monkeypatch, workspace):
    monkeypatch.setattr(workspace, '_default_guest_credentials', lambda: ('fixture-user', 'fixture-password'))
    calls = []
    def call(method, path, payload=None, **kwargs):
        calls.append((method, path, payload))
        if method == 'POST':
            return {'ok': True, 'job': {'id': 'a' * 32, 'state': 'queued'}}
        return {'ok': True, 'games': [{'id': 'fnf', 'title': 'FNF', 'available': True,
                'sourcePath': 'PRIVATE', 'releasePath': 'PRIVATE'}],
                'assignments': {'gaming': {'gameIds': ['fnf']}}}
    monkeypatch.setattr(workspace, '_vm_host', lambda _: SimpleNamespace(client=SimpleNamespace(_request=call)))
    return calls


def test_library_admin_and_csrf(workspace, monkeypatch):
    calls = host(monkeypatch, workspace)
    alice = login(workspace)
    assert alice.get('/EpicVM/api/management/games').status_code == 403
    assert post(alice, 'management/games/jobs', action='import').status_code == 403
    admin = login(workspace, 'rootadmin', dashboard=True)
    assert admin.get('/EpicVM/api/management/games').json['games'][0]['id'] == 'fnf'
    assert admin.post('/EpicVM/api/management/games/jobs', json={'action': 'import'}).status_code == 403
    assert post(admin, 'management/games/jobs', action='import', sourcePath='D:\\Game', id='fnf', title='FNF').status_code == 202
    assert calls[-1][1] == '/v1/game-library/jobs'


def test_assignment_checks_host_and_vm(workspace, monkeypatch):
    calls = host(monkeypatch, workspace)
    admin = login(workspace, 'rootadmin', dashboard=True)
    assert post(admin, 'management/games/jobs', action='assign', vmName='other', gameIds=['fnf']).status_code == 400
    assert post(admin, 'management/games/jobs', action='assign', vmName='gaming', gameIds='fnf').status_code == 400
    assert post(admin, 'management/games/jobs', action='assign', vmName='gaming', gameIds=[]).status_code == 202
    assert calls[-1][2]['guestCredential'] == {'username': 'fixture-user', 'password': 'fixture-password'}


def test_user_sees_only_assigned_machine_without_host_paths(workspace, monkeypatch):
    host(monkeypatch, workspace)
    workspace._update_user('alice', assigned_resources=['vm:epic-pc:one'])
    alice, bob = login(workspace), login(workspace, 'bob')
    result = alice.get('/EpicVM/api/account/games')
    assert result.status_code == 200
    assert result.json['machines'][0]['games'][0]['title'] == 'FNF'
    assert b'PRIVATE' not in result.data
    assert bob.get('/EpicVM/api/account/games').json['machines'] == []

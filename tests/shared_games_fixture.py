"""Isolated browser fixture for shared-game management and user visibility."""
import os
import sys
import tempfile
import shutil
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
state = tempfile.mkdtemp(prefix='epicvm-shared-game-browser-')
os.environ.update(BLOBEDASH_STATE=state, BLOBEDASH_USER='rootadmin', BLOBEDASH_PASS='admin-original',
                  DASH_V2_SECRET='local-game-fixture', BLOBEVM_USER_SECRET='local-game-portal')
os.environ.pop('BLOBEDASH_PASS_HASH', None)
os.environ.pop('BLOBEVM_ALLOW_INSECURE_DASHBOARD', None)
sys.path.insert(0, str(ROOT / 'dashboard'))
import app

resources = [{'resourceKey': 'vm:epic-pc:one', 'resourceType': 'vm', 'hostId': 'epic-pc',
              'nativeId': 'one', 'name': 'Fixture gaming PC', 'classification': 'managed',
              'available': True, 'profile': 'gaming', 'placement': 'remote', 'state': 'running', 'running': True}]
app._resource_inventory = lambda **kw: (resources, [])
app._default_guest_credentials = lambda: ('fixture-user', 'fixture-password')
class Registry:
    def refresh(self): pass
    def public_records(self):
        return [{'id': 'epic-pc', 'display_name': 'Fixture Hyper-V host', 'kind': 'remote',
                 'online': True, 'capabilities': {'create_vm': True, 'provisioning': True, 'gaming_provisioning': True}}]
app.VM_HOST_REGISTRY = Registry()
def pending(): return app.jsonify(ok=True, jobs=[], sunshineDefaultConfigured=True)
pending.__wrapped__ = pending
app.api_provisioning_jobs_pending = pending
library = {'ok': True, 'games': [{'id': 'fnf-dustin', 'title': 'FNF Dustin', 'sizeBytes': 2330000000,
            'available': True, 'sourcePath': 'C:\\Games\\FNF'}], 'assignments': {}}
jobs = {}
def call(method, path, payload=None, **kw):
    if method == 'GET' and path == '/v1/game-library': return library
    if method == 'GET': return {'ok': True, 'job': jobs[path.rsplit('/', 1)[-1]]}
    action = payload['action']
    if action == 'assign': library['assignments'][payload['vmName']] = {'gameIds': payload['gameIds']}
    if action == 'import': library['games'].append({'id': payload['id'], 'title': payload['title'], 'sizeBytes': 1000000, 'available': True})
    job = {'id': str(len(jobs) + 1).zfill(32), 'action': action, 'state': 'complete'}
    jobs[job['id']] = job
    return {'ok': True, 'job': {**job, 'state': 'queued'}}
app._vm_host = lambda _: SimpleNamespace(client=SimpleNamespace(_request=call))
app._create_user('alice', 'portal-original', assigned_resources=['vm:epic-pc:one'])
app._create_user('manager', 'portal-original', is_admin=True)
shutil.copytree(ROOT / 'epicvm_web' / 'dist', Path(state) / 'epicvm_web' / 'dist')
app.app.run(host='127.0.0.1', port=5201, threaded=True, use_reloader=False)

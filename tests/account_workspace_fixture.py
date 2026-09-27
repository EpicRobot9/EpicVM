"""Local-only browser fixture. Never points at production account state."""
import os
import sys
import tempfile
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
state = tempfile.mkdtemp(prefix='epicvm-account-browser-')
os.environ.update(BLOBEDASH_STATE=state, BLOBEDASH_USER='rootadmin', BLOBEDASH_PASS='admin-original',
                  DASH_V2_SECRET='local-browser-fixture-secret', BLOBEVM_USER_SECRET='local-portal-fixture-secret')
os.environ.pop('BLOBEDASH_PASS_HASH', None)
os.environ.pop('BLOBEVM_ALLOW_INSECURE_DASHBOARD', None)
sys.path.insert(0, str(ROOT / 'dashboard'))
import app

resources = [{'resourceKey': 'vm:epic-pc:fixture-one', 'resourceType': 'vm', 'hostId': 'epic-pc',
              'hostName': 'Fixture Hyper-V host', 'placement': 'remote', 'profile': 'gaming',
              'state': 'ready', 'running': True, 'nativeId': 'fixture-one', 'name': 'Fixture gaming PC',
              'classification': 'managed', 'available': True,
              'capabilities': {'powerStart': True, 'powerStop': True, 'restart': True, 'console': True}}]
app._resource_inventory = lambda **kw: (resources, [])
class FixtureHost:
    kind = 'remote'
    host_name = 'Fixture Hyper-V host'
    class Client:
        def _request(self, method, path, payload=None, timeout=30):
            return {'ok': True, 'games': [], 'assignments': {}}
    client = Client()
    def provisioning_jobs(self):
        return [{'id': 'ready-job', 'name': 'fixture-ready', 'profile': 'gaming', 'state': 'ready',
                 'updatedAt': '2026-09-21T18:00:00Z', 'completedStages': ['claim', 'guest_setup', 'network_setup', 'management_handoff', 'gaming_gpu_validation', 'streaming_setup', 'stream_validation']}]
class FixtureRegistry:
    providers = {'epic-pc': FixtureHost()}
    def refresh(self): pass
    def get(self, host_id='local'):
        return self.providers.get(host_id)
    def public_records(self):
        return [{'id': 'epic-pc', 'display_name': 'Fixture Hyper-V host', 'kind': 'remote',
                 'online': True, 'capabilities': {'create_vm': True, 'provisioning': True,
                 'gaming_provisioning': True, 'omarchy_provisioning': False}}]
app.VM_HOST_REGISTRY = FixtureRegistry()
def pending_jobs_fixture():
    return app.jsonify(ok=True, jobs=[], sunshineDefaultConfigured=True)
pending_jobs_fixture.__wrapped__ = pending_jobs_fixture
app.api_provisioning_jobs_pending = pending_jobs_fixture
app._create_user('alice', 'portal-original')
app._create_user('manager', 'portal-original', is_admin=True)
app._create_user('pendingmember', 'portal-original')
app._update_user('pendingmember', account_status='pending')
shutil.copytree(ROOT / 'epicvm_web' / 'dist', Path(state) / 'epicvm_web' / 'dist')
app.app.run(host='127.0.0.1', port=5199, threaded=True, use_reloader=False)

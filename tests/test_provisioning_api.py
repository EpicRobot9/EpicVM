import importlib.util
import os
import sys
import threading
import time
import pytest
from types import SimpleNamespace


def load_app(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.delenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", raising=False)
    path = os.path.join(os.path.dirname(__file__), "..", "dashboard", "app.py")
    monkeypatch.syspath_prepend(os.path.dirname(path))
    spec = importlib.util.spec_from_file_location("provisioning_api_test_app", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "_admin_credentials", lambda: ("operator", "dashboard-password"))
    monkeypatch.setattr(module, "_dashboard_secret", lambda: "dashboard-secret")
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: bool(token))
    return module


class FakeRemoteHost:
    kind = "remote"
    host_id = "epic-pc"
    host_name = "Epic PC"

    def public_record(self):
        return {"online": True, "capabilities": {"provisioning": True, "gaming_provisioning": True}}

    def provision(self, name, profile, spec=None, idempotency_key=None):
        self.provision_calls = getattr(self, "provision_calls", [])
        self.provision_calls.append({"name": name, "profile": profile, "spec": spec, "idempotency_key": idempotency_key})
        return {"job": {"id": "job-1", "name": name, "profile": profile, "state": "unclaimed"}, "claimToken": "one-use"}

    def list_vms(self):
        return [{"name": "alpha"}]

    def set_gaming_gpu_percent(self, name, percent, idempotency_key=None):
        self.gpu_partition_calls = getattr(self, "gpu_partition_calls", [])
        self.gpu_partition_calls.append({"name": name, "percent": percent, "idempotency_key": idempotency_key})
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def provisioning_status(self, job_id):
        return {"job": {"id": job_id, "state": "unclaimed"}}

    def provisioning_jobs(self):
        return [{
            "id": "job-1",
            "name": "alpha",
            "profile": "standard",
            "state": "unclaimed",
            "claimConsumed": False,
            "claimToken": "do-not-return",
            "claimHash": "do-not-return",
            "updatedAt": "2026-08-16T00:00:00Z",
        }]

    def claim_reissue(self, job_id):
        return {"job": {"id": job_id, "name": "alpha", "state": "unclaimed"}, "claimToken": "reissued-once"}

    def claim(self, job_id, username, password, claim_token):
        return {"job": {"id": job_id, "name": "alpha", "state": "streaming_setup", "tailnetIp": "100.111.82.1"}}

    def console_credentials(self, job_id, *, guest_username, guest_password, sunshine_username, sunshine_password):
        self.last_console_credentials = {
            "job_id": job_id,
            "guest_username": guest_username,
            "guest_password": guest_password,
            "sunshine_username": sunshine_username,
            "sunshine_password": sunshine_password,
        }
        return {"ok": True}

    def console_complete(self, job_id, route_prefix, guest_tcp_verified, **kwargs):
        self.console_complete_calls = getattr(self, "console_complete_calls", [])
        self.console_complete_calls.append({
            "job_id": job_id,
            "route_prefix": route_prefix,
            "guest_tcp_verified": guest_tcp_verified,
            **kwargs,
        })
        return {"job": {"id": job_id, "name": "alpha", "state": "ready", "consoleRoutePrefix": route_prefix}}

    def console_failed(self, job_id, code="console_failed"):
        return {"job": {"id": job_id, "name": "alpha", "state": "setup_failed:streaming", "errorCode": code}}

    def deprovision(self, name, confirm_name, idempotency_key=None):
        return {"job": {"id": "tear-1", "name": name, "state": "ready"}}

    def deprovisioning_status(self, job_id):
        return {"job": {"id": job_id, "state": "ready"}}


def test_agent_handoff_retries_only_explicit_busy(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    monkeypatch.setattr(module.time, 'sleep', lambda _: None)
    calls = []
    def operation():
        calls.append(True)
        if len(calls) == 1:
            raise module.VmHostUnavailable('busy', status=409, code='agent_busy')
        return 'accepted'
    assert module._await_agent_handoff(operation) == 'accepted'
    assert len(calls) == 2
    def uncertain():
        calls.append(True)
        raise module.VmHostUnavailable('timeout', status=504, code='timeout')
    with pytest.raises(module.VmHostUnavailable):
        module._await_agent_handoff(uncertain)
    assert len(calls) == 3


def attach_host(module):
    host = FakeRemoteHost()

    class Registry:
        @property
        def providers(self):
            return {host.host_id: host}

        def refresh(self):
            return None

        def get(self, host_id="local"):
            if host_id != host.host_id:
                raise module.VmHostUnavailable("missing", status=404, code="not_found")
            return host

    module.VM_HOST_REGISTRY = Registry()

    class Console:
        automatic = False
        def build_plan(self, name, guest_ip, username, password):
            return SimpleNamespace(name=name, route_prefix=f"/vm/{name}/")
        def stage_plan(self, plan):
            return None
        def start_staged(self, name):
            return {"ok": True, "routePrefix": f"/vm/{name}/", "guestTcpVerified": True}
        def stop_staged(self, name):
            return None
        def quarantine_staged(self, name):
            return None
        def teardown(self, **kwargs):
            return {"ok": True}
        def has_auto_login(self, name):
            return self.automatic
        def enable_auto_login(self, name, username, password):
            assert username == 'operator'
            assert password == 'transient-password'
            self.automatic = True
        def build_json_auth_data(self, name):
            assert self.automatic
            return 'encrypted-data'
    module._CONSOLE_ORCHESTRATOR = Console()


def authenticated_client(module):
    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "session")
    return client


def test_console_backend_accepts_shell_quoted_environment_value(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    monkeypatch.setenv("EPICVM_CONSOLE_BACKEND", "'moonlight'")
    module._CONSOLE_ORCHESTRATOR = None

    orchestrator = module._console_orchestrator()

    assert getattr(orchestrator, "backend", "") == "moonlight"


def test_dashboard_api_unauthorized_does_not_emit_browser_basic_challenge(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    response = module.app.test_client().get("/dashboard/api/auth/csrf")
    assert response.status_code == 401
    assert "WWW-Authenticate" not in response.headers


def test_mutating_provisioning_api_requires_session_csrf(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    no_csrf = client.post(
        "/dashboard/api/provisioning-jobs",
        json={"host_id": "epic-pc", "name": "alpha", "profile": "standard"},
        headers={"Origin": "http://localhost"},
    )
    assert no_csrf.status_code == 403

    token_response = client.get("/dashboard/api/auth/csrf")
    assert token_response.status_code == 200
    csrf = token_response.get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs",
        json={"host_id": "epic-pc", "name": "alpha", "profile": "standard"},
        headers={"Origin": "http://localhost", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 202
    assert response.headers["Cache-Control"] == "no-store"
    assert response.get_json()["claimToken"] == "one-use"


def test_provisioning_fails_closed_until_host_prerequisites_are_ready(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)

    class NotReadyHost(FakeRemoteHost):
        def public_record(self):
            return {"online": True, "capabilities": {"provisioning": False}}

    class Registry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            return NotReadyHost()

    module.VM_HOST_REGISTRY = Registry()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs",
        json={"host_id": "epic-pc", "name": "alpha", "profile": "standard"},
        headers={"Origin": "http://localhost", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 409
    assert response.get_json()["code"] == "provisioning_unavailable"


def test_claim_is_https_only_and_never_reflects_password(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    payload = {"host_id": "epic-pc", "username": "operator", "password": "transient", "claimToken": "one-use"}
    http_response = client.post(
        "/dashboard/api/provisioning-jobs/job-1/claim",
        json=payload,
        headers={"Origin": "http://localhost", "X-CSRF-Token": csrf},
    )
    assert http_response.status_code == 426
    assert "transient" not in http_response.get_data(as_text=True)

    https_response = client.post(
        "/dashboard/api/provisioning-jobs/job-1/claim",
        json=payload,
        headers={"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf},
    )
    assert https_response.status_code == 200
    assert https_response.headers["Cache-Control"] == "no-store"
    assert "transient" not in https_response.get_data(as_text=True)


def test_remote_409_is_preserved(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)

    class ConflictHost(FakeRemoteHost):
        def provision(self, *args, **kwargs):
            raise module.VmHostUnavailable("duplicate", status=409, code="conflict")

    class Registry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            return ConflictHost()

    module.VM_HOST_REGISTRY = Registry()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs",
        json={"host_id": "epic-pc", "name": "alpha", "profile": "standard"},
        headers={"Origin": "http://localhost", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 409


def test_console_retry_requires_failed_state_and_reentered_credentials(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)

    class RetryHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "setup_failed:streaming", "tailnetIp": "100.111.82.1"}}

    module.VM_HOST_REGISTRY.get = lambda host_id="local": RetryHost()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs/job-1/retry-console",
        json={"host_id": "epic-pc", "username": "operator", "password": "transient-password"},
        headers={"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 200
    body = response.get_json()
    assert body["pendingVisualValidation"] is True
    assert body["job"]["state"] == "streaming_setup"
    assert body["job"]["consoleVisualValidationPending"] is True
    assert "transient-password" not in response.get_data(as_text=True)


def test_console_retry_conflict_is_read_only(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)

    class InProgressHost(FakeRemoteHost):
        def __init__(self):
            self.failed_codes = []

        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "streaming_setup"}}

        def console_failed(self, job_id, code="console_failed"):
            self.failed_codes.append(code)
            return super().console_failed(job_id, code)

    host = InProgressHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs/job-1/retry-console",
        json={"host_id": "epic-pc", "username": "operator", "password": "transient-password"},
        headers={"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 409
    assert response.get_json()["error"]["code"] == "console_retry_not_allowed"
    assert host.failed_codes == []


def test_console_retry_ready_is_idempotent(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)

    class ReadyHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "ready", "consoleRoutePrefix": "/vm/alpha/"}}

    host = ReadyHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    response = client.post(
        "/dashboard/api/provisioning-jobs/job-1/retry-console",
        json={"host_id": "epic-pc", "username": "operator", "password": "transient-password"},
        headers={"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf},
    )
    assert response.status_code == 200
    assert response.get_json()["job"]["state"] == "ready"


def test_ready_console_repair_is_async_and_completes_ready_without_password_reflection(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    started = threading.Event()

    class RepairHost(FakeRemoteHost):
        def __init__(self):
            self.failed_codes = []

        def provisioning_status(self, job_id):
            return {
                "job": {
                    "id": job_id,
                    "name": "alpha",
                    "state": "ready",
                    "tailnetIp": "100.111.82.1",
                    "completedStages": ["claim", "guest_setup", "network_setup", "management_handoff", "streaming_setup", "stream_validation"],
                }
            }

        def console_failed(self, job_id, code="console_failed"):
            self.failed_codes.append(code)
            return super().console_failed(job_id, code)

        def console_credentials(self, job_id, **kwargs):
            assert kwargs["reconcile_only"] is True
            assert kwargs["guest_username"] == "operator"
            assert kwargs["guest_password"] == "guest-secret"
            return {"ok": True}

    class MoonlightRepair:
        backend = "moonlight"

        def repair_staged(self, name, **kwargs):
            started.set()
            assert name == "alpha"
            assert kwargs["guest_ip"] == "100.111.82.1"
            assert kwargs["route_name"] == "alpha--epic-pc"
            return {"ok": True, "routePrefix": "/vm/alpha--epic-pc/", "guestTcpVerified": True}

        def stop_staged(self, name):
            return None

    host = RepairHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    module._default_guest_credentials = lambda: ("operator", "guest-secret")
    module._CONSOLE_ORCHESTRATOR = MoonlightRepair()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    headers = {"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf}
    payload = {
        "host_id": "epic-pc",
        "sunshineUsername": "sun-user",
        "sunshinePassword": "sun-secret",
    }

    response = client.post("/dashboard/api/provisioning-jobs/job-1/repair-console", json=payload, headers=headers)
    assert response.status_code == 202
    body = response.get_json()
    assert body["pending"] is True
    assert body["job"]["state"] == "ready"
    assert body["job"]["consoleRepairPending"] is True
    assert "sun-secret" not in response.get_data(as_text=True)
    assert started.wait(1)

    deadline = time.time() + 2
    while time.time() < deadline:
        task = module._CONSOLE_RETRY_TASKS.get(("epic-pc", "job-1"))
        if task and task.get("status") == "ready":
            break
        time.sleep(0.01)
    assert task["status"] == "ready"
    assert task["routeReady"] is True
    assert task["visualValidationRequired"] is False
    assert task["kind"] == "repair"
    assert host.failed_codes == []
    assert set(host.console_complete_calls[-1]) == {"job_id", "route_prefix", "guest_tcp_verified"}
    assert host.console_complete_calls[-1]["guest_tcp_verified"] is True

    status = client.get("/dashboard/api/provisioning-jobs/job-1?host_id=epic-pc")
    assert status.status_code == 200
    status_job = status.get_json()["job"]
    assert status_job["state"] == "ready"
    assert status_job["consoleRepairOutcome"] == "ready"
    assert status_job.get("consoleVisualValidationPending") is not True


def test_remote_console_worker_rechecks_ready_state_before_credentials(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)

    class ReadyHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "ready", "consoleRoutePrefix": "/vm/alpha/"}}

        def console_credentials(self, *args, **kwargs):
            raise AssertionError("credentials must not be sent after ready")

    class ShouldNotRunOrchestrator:
        def quarantine_staged(self, name):
            raise AssertionError("Moonlight must not be touched after ready")

    host = ReadyHost()
    key = ("epic-pc", "job-1")
    module._CONSOLE_RETRY_TASKS[key] = {
        "operationId": "op-ready",
        "startedAt": time.time(),
        "status": "pending",
        "failureCode": "",
        "routeReady": False,
    }
    module._start_remote_moonlight_console_retry(
        host=host,
        host_id="epic-pc",
        job_id="job-1",
        name="alpha",
        guest_ip="100.111.82.1",
        route_name="alpha--epic-pc",
        guest_username="operator",
        guest_password="transient-password",
        sunshine_username="sun-user",
        sunshine_password="sun-password",
        orchestrator=ShouldNotRunOrchestrator(),
        operation_id="op-ready",
    )

    task = module._CONSOLE_RETRY_TASKS[key]
    assert task["status"] == "ready"
    assert task["routeReady"] is True
    assert task["failureCode"] == ""


def test_remote_network_recovery_completes_ready_without_visual_gate(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._default_guest_credentials = lambda: ('operator', 'guest-secret')
    module._default_sunshine_credentials = lambda: ('sun', 'sun-secret')

    class RecoveryHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "setup_failed:streaming", "tailnetIp": "100.111.82.1"}}

        def network_recovery(self, job_id, *, guest_username, guest_password, reverify=False):
            assert guest_username == "operator"
            assert reverify is True
            return {"job": {"id": job_id, "name": "alpha", "state": "streaming_setup", "tailnetIp": "100.111.82.4"}}

        def console_credentials(self, job_id, **kwargs):
            assert kwargs["reconcile_only"] is True
            return {"ok": True}

    class MoonlightRecovery:
        backend = "moonlight"

        def repair_staged(self, name, **kwargs):
            assert kwargs["guest_ip"] == "100.111.82.4"
            assert kwargs["route_name"] == "alpha--epic-pc"
            return {"ok": True, "routePrefix": "/vm/alpha--epic-pc/", "guestTcpVerified": True}

        def stop_staged(self, name):
            return None

    host = RecoveryHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    module._CONSOLE_ORCHESTRATOR = MoonlightRecovery()
    key = ("epic-pc", "job-1")
    module._start_remote_guest_network_recovery(
        host=host,
        host_id="epic-pc",
        job_id="job-1",
        name="alpha",
        route_name="alpha--epic-pc",
        guest_username="operator",
        guest_password="guest-secret",
        sunshine_username="sun",
        sunshine_password="sun-secret",
        orchestrator=module._CONSOLE_ORCHESTRATOR,
        operation_id="op-netrec",
    )

    task = module._CONSOLE_RETRY_TASKS[key]
    assert task["status"] == "ready"
    assert task["routeReady"] is True
    assert task["visualValidationRequired"] is False
    assert task["failureCode"] == ""
    assert set(host.console_complete_calls[-1]) == {"job_id", "route_prefix", "guest_tcp_verified"}
    assert host.console_complete_calls[-1]["guest_tcp_verified"] is True


def test_remote_moonlight_retry_returns_pending_and_deduplicates(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._default_sunshine_credentials = lambda: ('sun-user', 'sun-password')
    started = threading.Event()
    release = threading.Event()

    class PendingHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "setup_failed:streaming", "tailnetIp": "100.111.82.1"}}

        def console_credentials(self, *args, **kwargs):
            started.set()
            release.wait(2)

    class MoonlightConsole:
        backend = "moonlight"

        def quarantine_staged(self, name):
            return None

        def build_plan(self, name, guest_ip, route_name=None):
            return SimpleNamespace(route_prefix=f"/vm/{name}/")

        def stage_plan(self, plan):
            return None

        def start_staged(self, name):
            return {"routePrefix": f"/vm/{name}/", "guestTcpVerified": True}

        def pair_staged(self, name, sunshine_username, sunshine_password):
            return {"routePrefix": f"/vm/{name}/", "guestTcpVerified": True}

        def repair_staged(self, name, **kwargs):
            return {"ok": True, "routePrefix": f"/vm/{name}/", "guestTcpVerified": True}

        def stop_staged(self, name):
            return None

    host = PendingHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    module._CONSOLE_ORCHESTRATOR = MoonlightConsole()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    payload = {
        "host_id": "epic-pc",
        "username": "operator",
        "password": "transient-password",
        "sunshineUsername": "sun-user",
        "sunshinePassword": "sun-password",
    }
    headers = {"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf}
    response = client.post("/dashboard/api/provisioning-jobs/job-1/retry-console", json=payload, headers=headers)
    assert response.status_code == 202
    body = response.get_json()
    assert body["pending"] is True
    assert body["job"]["consoleRetryPending"] is True
    assert "transient-password" not in response.get_data(as_text=True)
    assert started.wait(1)

    duplicate = client.post("/dashboard/api/provisioning-jobs/job-1/retry-console", json=payload, headers=headers)
    assert duplicate.status_code == 409
    assert duplicate.get_json()["error"]["code"] == "console_retry_in_progress"

    release.set()
    deadline = time.time() + 2
    while time.time() < deadline and module._CONSOLE_RETRY_TASKS.get(('epic-pc', 'job-1'), {}).get('status') == 'pending':
        time.sleep(0.01)
    task = module._CONSOLE_RETRY_TASKS[('epic-pc', 'job-1')]
    assert task['status'] == 'ready'
    assert task['routeReady'] is True
    assert task['visualValidationRequired'] is False
    assert task['failureCode'] == ''
    assert set(host.console_complete_calls[-1]) == {'job_id', 'route_prefix', 'guest_tcp_verified'}
    assert host.console_complete_calls[-1]['guest_tcp_verified'] is True


def test_remote_moonlight_retry_publishes_safe_terminal_failure(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._default_sunshine_credentials = lambda: ('sun', 'sun-secret')

    class FailedHost(FakeRemoteHost):
        def provisioning_status(self, job_id):
            return {"job": {"id": job_id, "name": "alpha", "state": "setup_failed:streaming", "tailnetIp": "100.111.82.1"}}

        def console_credentials(self, *args, **kwargs):
            raise module.VmHostUnavailable("not shown", status=503, code="management_transport_failed")

    class MoonlightConsole:
        backend = "moonlight"
        def quarantine_staged(self, name): return None
        def stop_staged(self, name): return None

    host = FailedHost()
    module.VM_HOST_REGISTRY.get = lambda host_id="local": host
    module._CONSOLE_ORCHESTRATOR = MoonlightConsole()
    client = authenticated_client(module)
    csrf = client.get("/dashboard/api/auth/csrf").get_json()["csrfToken"]
    headers = {"Origin": "http://localhost", "X-Forwarded-Proto": "https", "X-CSRF-Token": csrf}
    payload = {"host_id": "epic-pc", "username": "operator", "password": "secret", "sunshineUsername": "sun", "sunshinePassword": "sun-secret"}
    response = client.post("/dashboard/api/provisioning-jobs/job-1/retry-console", json=payload, headers=headers)
    assert response.status_code == 202
    deadline = time.time() + 2
    while time.time() < deadline:
        task = module._CONSOLE_RETRY_TASKS.get(("epic-pc", "job-1"))
        if task and task.get("status") == "failed":
            break
        time.sleep(0.01)
    assert task["status"] == "failed"
    assert task["failureCode"] == "management_transport_failed"
    assert "secret" not in str(task)
    status = client.get("/dashboard/api/provisioning-jobs/job-1?host_id=epic-pc")
    assert status.status_code == 200
    body = status.get_json()["job"]
    assert body["consoleRetryOutcome"] == "failed"
    assert body["errorCode"] == "management_transport_failed"
    assert "secret" not in status.get_data(as_text=True)


def test_admin_can_enable_and_launch_automatic_console_without_password_reflection(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    setup = client.post(
        '/dashboard/api/console-credentials/alpha',
        json={'username':'operator','password':'transient-password'},
        headers={'Origin':'http://localhost','X-Forwarded-Proto':'https','X-CSRF-Token':csrf},
    )
    assert setup.status_code == 200
    assert 'transient-password' not in setup.get_data(as_text=True)
    assert setup.get_json()['launchUrl'] == '/dashboard/console/alpha/launch'
    paired_setup = client.get('/dashboard/console/alpha/setup')
    assert paired_setup.status_code == 302
    assert paired_setup.headers['Location'] == '/dashboard/console/alpha/launch'
    entry = client.get('/dashboard/console/alpha/')
    assert entry.status_code == 302
    assert entry.headers['Location'] == '/dashboard/console/alpha/setup'
    launch = client.get('/dashboard/console/alpha/launch')
    assert launch.status_code == 200
    body = launch.get_data(as_text=True)
    assert 'localStorage.removeItem("GUAC_AUTH_TOKEN")' in body
    assert 'sessionStorage.removeItem("GUAC_AUTH_TOKEN")' in body
    assert 'new URLSearchParams({data:"encrypted-data"})' in body
    assert '/vm/alpha/api/tokens' in body
    assert 'localStorage.setItem("GUAC_AUTH_TOKEN",JSON.stringify(result.authToken))' in body
    assert '/vm/alpha/?data=' not in body
    assert launch.headers['Cache-Control'] == 'no-store'


@pytest.mark.parametrize('state', ['queued', 'cloning', 'booting'])
def test_pending_queue_retains_creates_before_the_claim(monkeypatch, tmp_path, state):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.provisioning_jobs = lambda: [{
        'id': 'job-1', 'name': 'alpha', 'state': state, 'claimConsumed': False,
    }]
    jobs = authenticated_client(module).get('/dashboard/api/provisioning-jobs/pending').get_json()['jobs']
    assert len(jobs) == 1
    assert jobs[0]['job']['state'] == state
    assert jobs[0]['job']['claimAvailable'] is False


def test_repaired_failed_job_remains_selectable_for_visual_verification(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.provisioning_jobs = lambda: [{
        'id': 'job-1', 'name': 'alpha', 'state': 'setup_failed:streaming', 'claimConsumed': True,
    }]
    module._CONSOLE_RETRY_TASKS[('epic-pc', 'job-1')] = {
        'status': 'pending_visual', 'routePrefix': '/vm/alpha--epic-pc/',
    }
    jobs = authenticated_client(module).get('/dashboard/api/provisioning-jobs/pending').get_json()['jobs']
    assert len(jobs) == 1
    assert jobs[0]['job']['consoleVisualValidationPending'] is True
    assert jobs[0]['job']['consoleRoutePrefix'] == '/vm/alpha--epic-pc/'


@pytest.mark.parametrize('kind,returncode,expected_stops', [('remote', 0, ['alpha']), ('remote', 1, []), ('local', 0, [])])
def test_stopping_vm_releases_only_its_remote_console_after_success(monkeypatch, tmp_path, kind, returncode, expected_stops):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.kind = kind
    host.run_manager = lambda *args, **kwargs: SimpleNamespace(returncode=returncode, stdout='', stderr='')
    stopped = []
    module._CONSOLE_ORCHESTRATOR.stop_staged = stopped.append
    monkeypatch.setattr(module, '_moonlight_console', lambda orchestrator: True)
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post('/dashboard/api/stop/alpha?host_id=epic-pc', headers={'Origin': 'http://localhost', 'X-CSRF-Token': csrf})
    assert response.status_code == (502 if returncode else 200)
    assert stopped == expected_stops


def test_pending_remote_jobs_are_safe_and_survive_inventory_refresh(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)

    response = client.get('/dashboard/api/provisioning-jobs/pending')
    assert response.status_code == 200
    body = response.get_json()
    assert body['ok'] is True
    assert body['sunshineDefaultConfigured'] is False
    assert len(body['jobs']) == 1
    entry = body['jobs'][0]
    assert entry['host_id'] == 'epic-pc'
    assert entry['job']['id'] == 'job-1'
    assert entry['job']['state'] == 'unclaimed'
    assert 'claimToken' not in response.get_data(as_text=True)
    assert 'claimHash' not in response.get_data(as_text=True)


def test_claim_recovery_accepts_exact_job_id_without_relying_on_vm_name(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs/recover',
        json={'host_id': 'epic-pc', 'job_id': 'job-1'},
        headers={'Origin': 'http://localhost', 'X-Forwarded-Proto': 'https', 'X-CSRF-Token': csrf},
    )
    assert response.status_code == 200
    assert response.get_json()['claimToken'] == 'reissued-once'
    assert 'claimHash' not in response.get_data(as_text=True)


def test_claim_uses_protected_default_sunshine_credentials(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    module._default_sunshine_credentials = lambda: ('sun-default', 'sun-default-password')

    class MoonlightConsole:
        backend = 'moonlight'

        def build_plan(self, name, guest_ip, route_name=None):
            return SimpleNamespace(route_prefix=f'/vm/{route_name or name}/')

        def stage_plan(self, plan):
            return None

        def start_staged(self, name):
            return {'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def repair_staged(self, name, **kwargs):
            return {'ok': True, 'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def pair_staged(self, name, sunshine_username, sunshine_password):
            assert sunshine_username == 'sun-default'
            assert sunshine_password == 'sun-default-password'
            return {'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def repair_staged(self, name, **kwargs):
            return {'ok': True, 'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def stop_staged(self, name):
            return None

        def quarantine_staged(self, name):
            return None

    module._CONSOLE_ORCHESTRATOR = MoonlightConsole()
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs/job-1/claim',
        json={'host_id': 'epic-pc', 'username': 'chosen-user', 'password': 'chosen-password', 'claimToken': 'one-use', 'sunshineUsername': 'attacker', 'sunshinePassword': 'attacker-secret'},
        headers={'Origin': 'http://localhost', 'X-Forwarded-Proto': 'https', 'X-CSRF-Token': csrf},
    )
    assert response.status_code == 200
    body = response.get_json()
    assert body['pendingVisualValidation'] is True
    assert body['consoleRoutePrefix'] == '/vm/alpha--epic-pc/'
    assert body['job']['consoleVisualValidationPending'] is True
    assert host.last_console_credentials == {
        'job_id': 'job-1',
        'guest_username': 'chosen-user',
        'guest_password': 'chosen-password',
        'sunshine_username': 'sun-default',
        'sunshine_password': 'sun-default-password',
    }
    assert 'chosen-password' not in response.get_data(as_text=True)
    assert 'sun-default-password' not in response.get_data(as_text=True)


def test_console_verify_requires_transport_and_decoded_video_evidence(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.console_complete_calls = []

    def streaming_status(job_id):
        return {
            'job': {
                'id': job_id,
                'name': 'alpha',
                'profile': 'standard',
                'state': 'streaming_setup',
                'tailnetIp': '100.111.82.1',
            }
        }

    host.provisioning_status = streaming_status
    module.VM_HOST_REGISTRY.get = lambda host_id='local': host
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    headers = {
        'Origin': 'http://localhost',
        'X-Forwarded-Proto': 'https',
        'X-CSRF-Token': csrf,
    }
    base = {
        'host_id': 'epic-pc',
        'routePrefix': '/vm/alpha--epic-pc/',
        'guestTcpVerified': True,
        'frameMetrics': {
            'nonblackFraction': .75,
            'meanLuma': 40,
            'stdDev': 41,
            'decodedFramesDelta': 10,
            'durationMs': 2000,
        },
    }

    incomplete = client.post(
        '/dashboard/api/provisioning-jobs/job-1/console-verify',
        json={**base, 'guestTcpVerified': False},
        headers=headers,
    )
    assert incomplete.status_code == 422
    assert host.console_complete_calls == []

    complete = client.post(
        '/dashboard/api/provisioning-jobs/job-1/console-verify',
        json=base,
        headers=headers,
    )
    assert complete.status_code == 200
    body = complete.get_json()
    assert body['visualValidationComplete'] is True
    assert body['job']['consoleVisualValidationPending'] is False
    assert set(host.console_complete_calls[-1]) == {'job_id', 'route_prefix', 'guest_tcp_verified', 'frame_metrics'}
    assert host.console_complete_calls[-1]['guest_tcp_verified'] is True


@pytest.mark.parametrize('deferred', [False, True])
def test_automatic_mode_claims_with_protected_defaults_and_returns_no_claim_secret(monkeypatch, tmp_path, deferred):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.claimed = False
    module._default_guest_credentials = lambda: ('default-user', 'default-password')
    module._default_sunshine_credentials = lambda: ('sun-default', 'sun-default-password')
    started = threading.Event()

    def provision(name, profile, idempotency_key=None):
        if deferred:
            return {'job': {'id': 'job-auto', 'name': name, 'profile': profile, 'state': 'queued'}}
        return {
            'job': {'id': 'job-auto', 'name': name, 'profile': profile, 'state': 'unclaimed'},
            'claimToken': 'auto-one-use',
        }

    def claim(job_id, username, password, claim_token):
        assert username == 'default-user'
        assert password == 'default-password'
        assert claim_token == ('reissued-once' if deferred else 'auto-one-use')
        host.claimed = True
        return {'job': {'id': job_id, 'name': 'alpha', 'state': 'streaming_setup', 'tailnetIp': '100.111.82.1'}}

    def status(job_id):
        state = 'streaming_setup' if host.claimed else 'unclaimed'
        return {'job': {'id': job_id, 'name': 'alpha', 'state': state, 'tailnetIp': '100.111.82.1'}}

    host.provision = provision
    host.claim = claim
    host.provisioning_status = status
    original_console_credentials = host.console_credentials

    def console_credentials(*args, **kwargs):
        started.set()
        return original_console_credentials(*args, **kwargs)

    host.console_credentials = console_credentials

    class MoonlightConsole:
        backend = 'moonlight'

        def quarantine_staged(self, name):
            return None

        def build_plan(self, name, guest_ip, route_name=None):
            return SimpleNamespace(route_prefix=f'/vm/{route_name or name}/')

        def stage_plan(self, plan):
            return None

        def start_staged(self, name):
            return {'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def repair_staged(self, name, **kwargs):
            return {'ok': True, 'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def pair_staged(self, name, sunshine_username, sunshine_password):
            assert sunshine_username == 'sun-default'
            assert sunshine_password == 'sun-default-password'
            return {'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def repair_staged(self, name, **kwargs):
            return {'ok': True, 'routePrefix': f'/vm/{name}/', 'guestTcpVerified': True}

        def stop_staged(self, name):
            return None

    module._CONSOLE_ORCHESTRATOR = MoonlightConsole()
    module.VM_HOST_REGISTRY.get = lambda host_id='local': host
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs',
        json={'host_id': 'epic-pc', 'name': 'alpha', 'profile': 'standard', 'mode': 'automatic'},
        headers={'Origin': 'http://localhost', 'X-Forwarded-Proto': 'https', 'X-CSRF-Token': csrf},
    )
    assert response.status_code == 202
    body = response.get_json()
    assert body['pending'] is True
    assert body['mode'] == 'automatic'
    assert body['job']['autonomousPending'] is True
    assert 'claimToken' not in response.get_data(as_text=True)
    assert 'default-password' not in response.get_data(as_text=True)
    assert 'sun-default-password' not in response.get_data(as_text=True)
    assert started.wait(1)

    deadline = time.time() + 2
    while time.time() < deadline:
        task = module._CONSOLE_RETRY_TASKS.get(('epic-pc', 'job-auto'))
        if task and task.get('status') == 'ready':
            break
        time.sleep(0.01)
    assert task['status'] == 'ready'
    assert task['routeReady'] is True
    assert task['visualValidationRequired'] is False
    assert host.console_complete_calls[-1]['job_id'] == 'job-auto'
    assert host.console_complete_calls[-1]['guest_tcp_verified'] is True
    assert host.last_console_credentials == {
        'job_id': 'job-auto',
        'guest_username': 'default-user',
        'guest_password': 'default-password',
        'sunshine_username': 'sun-default',
        'sunshine_password': 'sun-default-password',
    }


def test_gaming_provisioning_forwards_only_initialization_resources(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs',
        json={
            'host_id': 'epic-pc',
            'name': 'gaming-alpha',
            'profile': 'gaming',
            'mode': 'claim',
            'cpuCount': 8,
            'memoryGiB': 16,
            'diskSizeGiB': 256,
            'gpuPartitionPercent': 65,
            'sunshinePassword': 'must-not-forward',
        },
        headers={'Origin': 'http://localhost', 'X-CSRF-Token': csrf},
    )
    assert response.status_code == 202
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    call = host.provision_calls[-1]
    assert call['profile'] == 'gaming'
    assert call['spec'] == {
        'cpuCount': 8,
        'memoryGiB': 16,
        'diskSizeGiB': 256,
        'gpuPartitionPercent': 65,
    }
    assert 'must-not-forward' not in response.get_data(as_text=True)


def test_gaming_partition_endpoint_updates_only_percent(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    headers = {'Origin': 'http://localhost', 'X-CSRF-Token': csrf}
    response = client.post(
        '/dashboard/api/vm/alpha/gpu-partition',
        json={'host_id': 'epic-pc', 'percent': 72},
        headers=headers,
    )
    assert response.status_code == 200
    assert response.get_json() == {'ok': True, 'host_id': 'epic-pc', 'name': 'alpha', 'percent': 72}
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    assert host.gpu_partition_calls[-1]['percent'] == 72

    invalid = client.post(
        '/dashboard/api/vm/alpha/gpu-partition',
        json={'host_id': 'epic-pc', 'percent': 101},
        headers=headers,
    )
    assert invalid.status_code == 400
    assert host.gpu_partition_calls[-1]['percent'] == 72


def test_omarchy_provisioning_uses_its_own_capability_and_resource_payload(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.public_record = lambda: {
        'online': True,
        'capabilities': {
            'provisioning': True,
            'omarchy_provisioning': True,
            'omarchyProvisioningChecks': {'pilotValidated': True},
        },
    }
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs',
        json={
            'host_id': 'epic-pc',
            'name': 'omarchy-alpha',
            'profile': 'omarchy',
            'mode': 'claim',
            'cpuCount': 8,
            'memoryGiB': 16,
            'diskSizeGiB': 256,
            'gpuPartitionPercent': 65,
            'password': 'must-not-forward',
        },
        headers={'Origin': 'http://localhost', 'X-CSRF-Token': csrf},
    )

    assert response.status_code == 202
    call = host.provision_calls[-1]
    assert call['profile'] == 'omarchy'
    assert call['spec'] == {
        'cpuCount': 8,
        'memoryGiB': 16,
        'diskSizeGiB': 256,
        'gpuPartitionPercent': 65,
    }
    assert 'must-not-forward' not in response.get_data(as_text=True)


def test_omarchy_provisioning_rejects_hosts_without_the_experimental_capability(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    attach_host(module)
    host = module.VM_HOST_REGISTRY.get('epic-pc')
    host.public_record = lambda: {
        'online': True,
        'capabilities': {
            'provisioning': True,
            'omarchy_provisioning': False,
            'omarchyProvisioningChecks': {'pilotValidated': False},
        },
    }
    client = authenticated_client(module)
    csrf = client.get('/dashboard/api/auth/csrf').get_json()['csrfToken']
    response = client.post(
        '/dashboard/api/provisioning-jobs',
        json={'host_id': 'epic-pc', 'name': 'omarchy-alpha', 'profile': 'omarchy'},
        headers={'Origin': 'http://localhost', 'X-CSRF-Token': csrf},
    )

    assert response.status_code == 409
    body = response.get_json()
    assert body['code'] == 'omarchy_provisioning_unavailable'
    assert 'experimental AMD GPU-P pilot' in body['error']
    assert not getattr(host, 'provision_calls', [])


def test_omarchy_inventory_and_job_serialization_identify_linux_without_claim_material(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    safe = module._safe_provisioning_job({
        'id': 'job-omarchy',
        'name': 'omarchy-alpha',
        'profile': 'omarchy',
        'guestOs': 'Omarchy Linux',
        'guestUsername': 'operator',
        'claimHash': 'secret-hash',
        'claimToken': 'secret-token',
        'password': 'secret-password',
    })

    assert safe['profile'] == 'omarchy'
    assert safe['guestOs'] == 'Omarchy Linux'
    assert safe['guestUsername'] == 'operator'
    assert 'claimHash' not in safe
    assert 'claimToken' not in safe
    assert 'password' not in safe
    source = open(module.__file__, encoding='utf-8').read()
    assert "vm_type = 'omarchy'" in source
    assert "'Omarchy Linux' if vm_type == 'omarchy'" in source

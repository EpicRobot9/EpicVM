import importlib.util
import json
import sys
from pathlib import Path


APP_PATH = Path("/opt/blobe-vm/repo/dashboard/app.py")
if not APP_PATH.is_file():
    APP_PATH = Path(__file__).resolve().parents[1] / "dashboard" / "app.py"


def load_app(monkeypatch):
    monkeypatch.setenv("BLOBEDASH_STATE", "/tmp/blobevm-test-state")
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    spec = importlib.util.spec_from_file_location("blobedash_test_app", str(APP_PATH))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_admin_vm_sso_is_enabled_by_default(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))

    assert module._admin_vm_sso_enabled() is True


def test_admin_vm_sso_setting_can_be_disabled(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    (tmp_path / "dashboard_settings.json").write_text(
        json.dumps({"admin_vm_sso": False}), encoding="utf-8"
    )

    assert module._admin_vm_sso_enabled() is False


def test_forward_auth_accepts_dashboard_admin_session_when_enabled(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: {"admin": True} if token else None)
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "valid-admin-session")
    response = client.get("/dashboard/auth/vm/alpha")

    assert response.status_code == 200


def test_forward_auth_does_not_use_dashboard_admin_session_when_disabled(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    (tmp_path / "dashboard_settings.json").write_text(
        json.dumps({"admin_vm_sso": False}), encoding="utf-8"
    )
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: {"admin": True} if token else None)
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    response = module.app.test_client().get(
        "/dashboard/auth/vm/alpha",
        headers={"Cookie": "Dashboard-Auth=valid-admin-session"},
    )

    assert response.status_code == 302
    assert "/portal/login" in response.headers["Location"]


def test_forward_auth_preflights_scoped_moonlight_host_request(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: {"admin": True} if token else None)
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")
    monkeypatch.setattr(module, "_console_route_host_id", lambda name, forwarded_uri: "epic-pc")
    calls = []

    def reconcile(name, host_id, *, wait=False, wait_timeout=90.0, allow_pending_visual=False):
        calls.append((name, host_id, wait, wait_timeout, allow_pending_visual))
        return {"ok": True, "healthy": True}

    monkeypatch.setattr(module, "_reconcile_remote_console", reconcile)
    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "valid-admin-session")
    response = client.get(
        "/dashboard/auth/vm/gaming-gpup-pilot-03",
        headers={
            "X-Forwarded-Uri": "/vm/gaming-gpup-pilot-03--epic-pc/api/host?host_id=3414349171",
        },
    )

    assert response.status_code == 200
    assert calls == [("gaming-gpup-pilot-03", "epic-pc", True, 150.0, True)]


def test_forward_auth_verification_cache_reuses_application_level_success(monkeypatch):
    module = load_app(monkeypatch)
    calls = []

    def reconcile(name, host_id, *, wait=False, wait_timeout=90.0, allow_pending_visual=False):
        calls.append((name, host_id, wait, wait_timeout, allow_pending_visual))
        return {
            "ok": True,
            "healthy": False,
            "pending": True,
            "routeReady": True,
            "visualValidationRequired": True,
        }

    monkeypatch.setattr(module, "_reconcile_remote_console", reconcile)
    first = module._remote_console_forward_auth_verify("gaming-gpup-pilot-03", "epic-pc")
    second = module._remote_console_forward_auth_verify("gaming-gpup-pilot-03", "epic-pc")

    assert first["routeReady"] is True
    assert second["visualValidationRequired"] is True
    assert calls == [("gaming-gpup-pilot-03", "epic-pc", True, 150.0, True)]


def test_forward_auth_verification_cache_coalesces_inflight_requests(monkeypatch):
    module = load_app(monkeypatch)
    import threading
    import time

    calls = []
    started = threading.Event()
    release = threading.Event()

    def reconcile(name, host_id, *, wait=False, wait_timeout=90.0, allow_pending_visual=False):
        calls.append((name, host_id))
        started.set()
        assert release.wait(2.0)
        return {"ok": True, "healthy": True}

    monkeypatch.setattr(module, "_reconcile_remote_console", reconcile)
    results = []

    def invoke():
        results.append(module._remote_console_forward_auth_verify("gaming-gpup-pilot-03", "epic-pc"))

    first = threading.Thread(target=invoke)
    second = threading.Thread(target=invoke)
    first.start()
    assert started.wait(1.0)
    second.start()
    time.sleep(0.05)
    release.set()
    first.join(2.0)
    second.join(2.0)

    assert len(results) == 2
    assert all(result["healthy"] is True for result in results)
    assert calls == [("gaming-gpup-pilot-03", "epic-pc")]


def test_gaming_route_can_reach_paired_moonlight_while_visual_validation_is_pending(monkeypatch):
    module = load_app(monkeypatch)

    class Orchestrator:
        backend = "moonlight"

        def verify_staged(self, name, *, guest_ip, route_name):
            assert name == "gaming-gpup-pilot-03"
            assert guest_ip == "100.111.87.90"
            assert route_name == "gaming-gpup-pilot-03--epic-pc"
            return {
                "routePrefix": "/vm/gaming-gpup-pilot-03--epic-pc/",
                "guestTcpVerified": True,
                "hostApiVerified": True,
            }

    class Host:
        kind = "remote"

    monkeypatch.setattr(module, "_console_orchestrator", lambda: Orchestrator())
    monkeypatch.setattr(module, "_vm_host", lambda host_id: Host())
    monkeypatch.setattr(
        module,
        "_remote_console_job",
        lambda host, name: {
            "job_id": "job-gaming-pending-visual",
            "guest_ip": "100.111.87.90",
            "job": {
                "name": name,
                "profile": "gaming",
                "state": "setup_failed:streaming",
                "gamingCaptureConfigured": False,
            },
        },
    )
    monkeypatch.setattr(
        module,
        "_queue_remote_console_repair",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("agent repair must not block browser evidence")),
    )

    result = module._reconcile_remote_console(
        "gaming-gpup-pilot-03",
        "epic-pc",
        allow_pending_visual=True,
    )

    assert result["routeReady"] is True
    assert result["visualValidationRequired"] is True
    assert result["gamingCaptureConfigured"] is False
    assert result["healthy"] is False
    assert result["pending"] is True


def test_remote_console_entry_renders_retry_page_before_moonlight_is_ready(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_admin_credentials", lambda: ("Epic", "test-password"))
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: {"admin": True} if token else None)
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")
    monkeypatch.setattr(
        module,
        "_reconcile_remote_console",
        lambda *args, **kwargs: {"ok": True, "healthy": False, "pending": True, "failureCode": "console_repair_pending"},
    )

    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "valid-admin-session")
    response = client.get("/dashboard/console/testprov/?host_id=epic-pc")

    assert response.status_code == 200
    assert "Remote console warming up" in response.get_data(as_text=True)
    assert "The VM is running" in response.get_data(as_text=True)
    assert response.headers["Retry-After"] == "3"
    assert response.headers["X-EpicVM-Console-Code"] == "console_repair_pending"
    assert response.headers["Cache-Control"] == "no-store"


def test_ready_remote_console_queues_guest_network_recovery_on_sunshine_unavailable(monkeypatch):
    module = load_app(monkeypatch)
    calls = []

    class Orchestrator:
        backend = "moonlight"

        def verify_staged(self, *args, **kwargs):
            raise module.ConsoleOrchestrationError(
                "guest unavailable",
                status=503,
                code="sunshine_tcp_unavailable",
            )

    class Host:
        kind = "remote"

    monkeypatch.setattr(module, "_console_orchestrator", lambda: Orchestrator())
    monkeypatch.setattr(module, "_vm_host", lambda host_id: Host())
    monkeypatch.setattr(
        module,
        "_remote_console_job",
        lambda host, name: {
            "job_id": "job-ready-network",
            "guest_ip": "100.83.6.71",
            "job": {"name": name, "state": "ready"},
        },
    )
    monkeypatch.setattr(
        module,
        "_queue_remote_guest_network_recovery",
        lambda **kwargs: calls.append(kwargs) or {
            "ok": True,
            "healthy": False,
            "pending": True,
            "failureCode": "network_recovery_pending",
        },
    )
    monkeypatch.setattr(
        module,
        "_queue_remote_console_repair",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("bundle repair must not be queued first")),
    )

    result = module._reconcile_remote_console("claimmode-canary-1", "epic-pc", wait=False)

    assert result["failureCode"] == "network_recovery_pending"
    assert calls and calls[0]["job_id"] == "job-ready-network"
    assert calls[0]["name"] == "claimmode-canary-1"


def test_guest_network_recovery_worker_repairs_with_new_verified_address(monkeypatch):
    module = load_app(monkeypatch)
    task_key = ("epic-pc", "job-ready-network")
    module._CONSOLE_RETRY_TASKS.clear()
    module._CONSOLE_RETRY_TASKS[task_key] = {
        "operationId": "op-network",
        "status": "pending",
        "startedAt": 1,
        "kind": "network_recovery",
    }
    calls = []

    class Host:
        def provisioning_status(self, job_id):
            return {"job": {"state": "ready", "name": "claimmode-canary-1"}}

        def network_recovery(self, job_id, **kwargs):
            calls.append(("network_recovery", job_id, kwargs))
            return {"job": {"state": "streaming_setup", "tailnetIp": "100.83.6.72"}}

        def console_credentials(self, job_id, **kwargs):
            calls.append(("console_credentials", job_id, kwargs))
            return {"ok": True}

        def console_complete(self, job_id, **kwargs):
            calls.append(("console_complete", job_id, kwargs))
            return {"ok": True, "job": {"state": "ready"}}

    class Orchestrator:
        def repair_staged(self, *args, **kwargs):
            calls.append(("repair_staged", args, kwargs))
            return {"ok": True, "routePrefix": "/vm/claimmode-canary-1--epic-pc/", "guestTcpVerified": True}

    module._start_remote_guest_network_recovery(
        host=Host(),
        host_id="epic-pc",
        job_id="job-ready-network",
        name="claimmode-canary-1",
        route_name="claimmode-canary-1--epic-pc",
        guest_username="operator",
        guest_password="transient-password",
        sunshine_username="sunshine",
        sunshine_password="sunshine-password",
        orchestrator=Orchestrator(),
        operation_id="op-network",
    )

    assert calls[0] == (
        "network_recovery",
        "job-ready-network",
        {"guest_username": "operator", "guest_password": "transient-password", "reverify": True},
    )
    assert any(item[0] == "repair_staged" and item[2]["guest_ip"] == "100.83.6.72" for item in calls)
    completion = next(item for item in calls if item[0] == "console_complete")
    assert set(completion[2]) == {"route_prefix", "guest_tcp_verified"}
    assert completion[2]["guest_tcp_verified"] is True
    task = module._CONSOLE_RETRY_TASKS[task_key]
    assert task["status"] == "ready"
    assert task["routeReady"] is True
    assert task["visualValidationRequired"] is False
    assert "transient-password" not in repr(module._CONSOLE_RETRY_TASKS)


def test_guest_network_recovery_worker_revalidates_streaming_failure(monkeypatch):
    module = load_app(monkeypatch)
    task_key = ("epic-pc", "job-streaming-network")
    module._CONSOLE_RETRY_TASKS.clear()
    module._CONSOLE_RETRY_TASKS[task_key] = {
        "operationId": "op-streaming-network",
        "status": "pending",
        "startedAt": 1,
        "kind": "network_recovery",
    }
    calls = []

    class Host:
        def provisioning_status(self, job_id):
            return {"job": {"state": "setup_failed:streaming", "name": "testprovvm-autonomous-1"}}

        def network_recovery(self, job_id, **kwargs):
            calls.append(("network_recovery", job_id, kwargs))
            return {"job": {"state": "streaming_setup", "tailnetIp": "100.124.226.19"}}

        def console_credentials(self, job_id, **kwargs):
            calls.append(("console_credentials", job_id, kwargs))
            return {"ok": True}

        def console_complete(self, job_id, **kwargs):
            calls.append(("console_complete", job_id, kwargs))
            return {"ok": True, "job": {"state": "ready"}}

    class Orchestrator:
        def repair_staged(self, *args, **kwargs):
            calls.append(("repair_staged", args, kwargs))
            return {"ok": True, "routePrefix": "/vm/testprovvm-autonomous-1--epic-pc/", "guestTcpVerified": True}

    module._start_remote_guest_network_recovery(
        host=Host(),
        host_id="epic-pc",
        job_id="job-streaming-network",
        name="testprovvm-autonomous-1",
        route_name="testprovvm-autonomous-1--epic-pc",
        guest_username="operator",
        guest_password="transient-password",
        sunshine_username="sunshine",
        sunshine_password="sunshine-password",
        orchestrator=Orchestrator(),
        operation_id="op-streaming-network",
    )

    assert calls[0] == (
        "network_recovery",
        "job-streaming-network",
        {"guest_username": "operator", "guest_password": "transient-password", "reverify": True},
    )
    assert any(item[0] == "repair_staged" and item[2]["guest_ip"] == "100.124.226.19" for item in calls)
    completion = next(item for item in calls if item[0] == "console_complete")
    assert set(completion[2]) == {"route_prefix", "guest_tcp_verified"}
    assert completion[2]["guest_tcp_verified"] is True
    task = module._CONSOLE_RETRY_TASKS[task_key]
    assert task["status"] == "ready"
    assert task["routeReady"] is True
    assert task["visualValidationRequired"] is False


def test_forward_auth_does_not_preflight_unrelated_vm_requests(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: {"admin": True} if token else None)
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")
    calls = []
    monkeypatch.setattr(module, "_reconcile_remote_console", lambda *args, **kwargs: calls.append((args, kwargs)))
    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "valid-admin-session")
    response = client.get(
        "/dashboard/auth/vm/gaming-gpup-pilot-03",
        headers={"X-Forwarded-Uri": "/vm/gaming-gpup-pilot-03--epic-pc/index.html"},
    )

    assert response.status_code == 200
    assert calls == []


def test_settings_endpoint_persists_admin_vm_sso_toggle(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_admin_credentials", lambda: ("Epic", "test-password"))
    monkeypatch.setattr(module, "_dashboard_secret", lambda: "test-secret")
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: bool(token))

    client = module.app.test_client()
    client.set_cookie("Dashboard-Auth", "valid-admin-session")
    response = client.post(
        "/dashboard/api/settings",
        json={"adminVmSso": False},
        headers={
            "Origin": "http://localhost",
            "X-CSRF-Token": module._csrf_token_for_session("valid-admin-session"),
        },
    )

    assert response.status_code == 200
    assert module._admin_vm_sso_enabled() is False


def test_vm_wrapper_accepts_dashboard_admin_session_when_enabled(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: None)
    monkeypatch.setattr(module, "_verify_v2_token", lambda token: bool(token))
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    with module.app.test_request_context(
        "/vm/alpha/", headers={"Cookie": "Dashboard-Auth=valid-admin-session"}
    ):
        assert module._enforce_vm_user_access("alpha") is None


def test_restricted_vm_denial_login_returns_to_local_requested_vm(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: {"username": "other", "assignedVms": []})
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    response = module.app.test_client().get("/dashboard/vm/alpha/?tab=console")

    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert 'location.href="/dashboard/vm/alpha/?tab=console"' in body


def test_restricted_vm_denial_login_returns_to_epicvm_requested_vm(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: {"username": "other", "assignedVms": []})
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    response = module.app.test_client().get("/EpicVM/vm/alpha/?tab=console")

    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert 'location.href="/EpicVM/vm/alpha/?tab=console"' in body


def test_restricted_vm_denial_escapes_query_before_inline_login_redirect(monkeypatch, tmp_path):
    module = load_app(monkeypatch)
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setattr(module, "_current_portal_user", lambda: {"username": "other", "assignedVms": []})
    monkeypatch.setattr(module, "_vm_access_mode", lambda name: "restricted")

    response = module.app.test_client().get(
        "/dashboard/vm/alpha/?tab=</script><script>alert(1)</script>"
    )

    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert "</script><script>" not in body
    assert r"\u003c/script\u003e\u003cscript\u003ealert(1)\u003c/script\u003e" in body

import json
import os
import stat
import sys
from io import BytesIO
from types import SimpleNamespace
from urllib.error import HTTPError

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "dashboard"))

from dashboard.remote_hosts import (
    ConfiguredVmHostRegistry,
    RemoteHostConfigError,
    load_remote_host_configs,
)
from dashboard.remote_agent_client import RemoteAgentClient, RemoteAgentError, RemoteAgentHost
from dashboard.vm_hosts import LocalDockerHost, VmHostUnavailable


def test_load_configs_redacts_tokens_and_rejects_duplicate_ids(tmp_path, monkeypatch):
    monkeypatch.setenv("EPICVM_ALLOW_PLAINTEXT_REMOTE_HOST_TOKENS", "1")
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({
        "version": 1,
        "hosts": [{
            "id": "epic-pc",
            "display_name": "Epic PC",
            "platform": "windows",
            "provider": "hyperv",
            "agent_url": "http://100.72.220.117:8765",
            "token": "secret-token",
            "enabled": True,
        }],
    }))
    path.chmod(0o600)

    configs = load_remote_host_configs(path)
    assert configs[0]["id"] == "epic-pc"
    assert "token" in configs[0]

    registry = ConfiguredVmHostRegistry(LocalDockerHost(manager="manager"), path)
    public = registry.public_records()
    remote = next(item for item in public if item["id"] == "epic-pc")
    assert "token" not in remote
    assert remote["provider"] == "hyperv"

    path.write_text(json.dumps({
        "version": 1,
        "hosts": [
            {"id": "same", "display_name": "A", "agent_url": "http://100.64.0.2:1", "token": "a"},
            {"id": "same", "display_name": "B", "agent_url": "http://100.64.0.3:1", "token": "b"},
        ],
    }))
    path.chmod(0o600)
    with pytest.raises(RemoteHostConfigError, match="duplicate"):
        load_remote_host_configs(path)


def test_registry_marks_unreachable_host_offline_without_hiding_local(tmp_path, monkeypatch):
    monkeypatch.setenv("EPICVM_ALLOW_PLAINTEXT_REMOTE_HOST_TOKENS", "1")
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({
        "version": 1,
        "hosts": [{
            "id": "offline-pc",
            "display_name": "Offline PC",
            "agent_url": "http://100.64.0.2:8765",
            "token": "secret-token",
            "enabled": True,
        }],
    }))
    path.chmod(0o600)
    registry = ConfiguredVmHostRegistry(LocalDockerHost(manager="manager"), path)
    registry._providers["offline-pc"].client = SimpleNamespace(
        health=lambda: (_ for _ in ()).throw(RemoteAgentError("offline")),
        capabilities=lambda: {},
    )

    records = registry.public_records()
    assert any(item["id"] == "local" for item in records)
    offline = next(item for item in records if item["id"] == "offline-pc")
    assert offline["online"] is False
    assert offline["capabilities"]["create_vm"] is False


def test_registry_rejects_group_or_world_readable_secret_file(tmp_path):
    if os.name == "nt":
        pytest.skip("Windows chmod does not expose DACL restrictions through st_mode")
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({"hosts": []}))
    path.chmod(0o644)

    with pytest.raises(RemoteHostConfigError, match="group/world readable"):
        load_remote_host_configs(path)


def test_registry_rejects_invalid_timeout_without_startup_exception(tmp_path, monkeypatch):
    monkeypatch.setenv("EPICVM_ALLOW_PLAINTEXT_REMOTE_HOST_TOKENS", "1")
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({
        "hosts": [{
            "id": "epic-pc",
            "display_name": "Epic PC",
            "agent_url": "http://100.64.0.2:8765",
            "token": "secret-token",
            "timeout": "not-a-number",
        }],
    }))
    path.chmod(0o600)

    with pytest.raises(RemoteHostConfigError, match="invalid timeout"):
        load_remote_host_configs(path)


def test_registry_persists_remote_inventory_cache_for_offline_cards(tmp_path):
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({"hosts": []}))
    path.chmod(0o600)
    registry = ConfiguredVmHostRegistry(LocalDockerHost(manager="manager"), path)
    registry.remember_inventory("epic-pc", [{"name": "alpha", "host_id": "epic-pc", "token": "must-not-persist"}])
    if os.name != "nt":
        assert stat.S_IMODE(registry.inventory_cache_path.stat().st_mode) == 0o600

    reloaded = ConfiguredVmHostRegistry(LocalDockerHost(manager="manager"), path)
    assert reloaded.cached_inventory("epic-pc") == [{"name": "alpha", "host_id": "epic-pc"}]


def test_remote_agent_client_sends_token_and_parses_vm_list(monkeypatch):
    calls = []

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return json.dumps({"vms": [{"name": "alpha", "state": "Running"}]}).encode()

    def fake_open(req, timeout):
        calls.append((req, timeout))
        return FakeResponse()

    client = RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open)
    result = client.list_vms()
    assert result == [{"name": "alpha", "state": "Running"}]
    assert calls[0][0].get_header("Authorization") == "Bearer token"
    assert calls[0][1] <= 3


def test_remote_create_uses_long_operation_timeout():
    calls = []

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return b'{"ok": true}'

    def fake_open(req, timeout):
        calls.append(timeout)
        return FakeResponse()

    RemoteAgentClient(
        "http://100.64.0.2:8765",
        "token",
        timeout=2.0,
        opener=fake_open,
    ).create("alpha")

    assert calls[0] >= 600


def test_remote_provisioning_status_has_bounded_store_read_timeout():
    calls = []

    class FakeResponse:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def read(self): return b'{"job":{"state":"setup_failed:streaming"}}'

    def fake_open(req, timeout):
        calls.append(timeout)
        return FakeResponse()

    RemoteAgentClient("http://100.64.0.2:8765", "token", timeout=2.0, opener=fake_open).provisioning_status("job-1")
    assert calls[0] == 30


def test_remote_network_recovery_forwards_reverify_without_logging_credentials():
    calls = []

    class FakeResponse:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *args): return False
        def read(self): return b'{"ok":true,"job":{"state":"streaming_setup"}}'

    def fake_open(req, timeout):
        calls.append((req, timeout))
        return FakeResponse()

    RemoteAgentClient("http://100.64.0.2:8765", "token", timeout=2.0, opener=fake_open).network_recovery(
        "job-ready-1",
        guest_username="operator",
        guest_password="transient-password",
        reverify=True,
    )

    request, timeout = calls[0]
    assert request.get_method() == "POST"
    assert request.full_url.endswith("/v1/provisioning-jobs/job-ready-1/network-recovery")
    assert json.loads(request.data.decode("utf-8")) == {
        "username": "operator",
        "password": "transient-password",
        "reverify": True,
    }
    assert timeout == 600


def test_remote_gaming_provision_forwards_initial_resources_and_partition_percent():
    calls = []

    class FakeResponse:
        status = 202

        def __enter__(self): return self
        def __exit__(self, *args): return False
        def read(self): return b'{"ok": true, "job": {"id": "job-1"}}'

    def fake_open(req, timeout):
        calls.append(req)
        return FakeResponse()

    RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open).provision(
        "game", "gaming", spec={"cpuCount": 6, "memoryBytes": 12884901888, "diskSizeBytes": 137438953472, "gpuPartitionPercent": 62}
    )

    payload = json.loads(calls[0].data.decode("utf-8"))
    assert payload == {
        "name": "game",
        "profile": "gaming",
        "cpuCount": 6,
        "memoryBytes": 12884901888,
        "diskSizeBytes": 137438953472,
        "gpuPartitionPercent": 62,
    }


def test_remote_gaming_partition_update_uses_dedicated_route():
    calls = []

    class FakeResponse:
        status = 200

        def __enter__(self): return self
        def __exit__(self, *args): return False
        def read(self): return b'{"ok": true, "vm": {"name": "game"}}'

    def fake_open(req, timeout):
        calls.append(req)
        return FakeResponse()

    RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open).set_gaming_gpu_percent("game", 75)

    assert calls[0].get_method() == "POST"
    assert calls[0].full_url == "http://100.64.0.2:8765/v1/vms/game/gpu-partition"
    assert json.loads(calls[0].data.decode("utf-8")) == {"percent": 75}
    assert calls[0].get_header("Idempotency-key")


def test_remote_lifecycle_uses_explicit_agent_contract_routes():
    calls = []

    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return b'{"ok": true, "vm": {"name": "alpha"}}'

    def fake_open(req, timeout):
        calls.append((req.get_method(), req.full_url))
        return FakeResponse()

    client = RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open)
    client.lifecycle("start", "alpha")
    client.lifecycle("delete", "alpha")

    assert calls == [
        ("POST", "http://100.64.0.2:8765/v1/vms/alpha/start"),
        ("DELETE", "http://100.64.0.2:8765/v1/vms/alpha"),
    ]


def test_remote_mutations_send_idempotency_key_and_capture_request_id():
    class FakeResponse:
        status = 200
        headers = {"X-Request-Id": "request-123"}

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return b'{"ok": true}'

    seen = []

    def fake_open(req, timeout):
        seen.append(req)
        return FakeResponse()

    result = RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open).lifecycle("start", "alpha")
    assert seen[0].get_header("Idempotency-key")
    assert result.request_id == "request-123"


def test_remote_client_rejects_malformed_success_json():
    class FakeResponse:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return b"not-json"

    with pytest.raises(RemoteAgentError, match="invalid JSON"):
        RemoteAgentClient(
            "http://100.64.0.2:8765",
            "token",
            opener=lambda req, timeout: FakeResponse(),
        ).health()


def test_remote_client_normalizes_http_errors_without_unbound_request_state():
    def fake_open(req, timeout):
        raise HTTPError(
            req.full_url,
            404,
            "not found",
            {"X-Request-Id": "request-404"},
            BytesIO(b'{"error": "missing"}'),
        )

    with pytest.raises(RemoteAgentError) as caught:
        RemoteAgentClient("http://100.64.0.2:8765", "token", opener=fake_open).health()
    assert caught.value.status == 404
    assert "missing" in str(caught.value)


def test_remote_capability_features_make_agent_eligible():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        health=lambda: {"ok": True},
        capabilities=lambda: {
            "ok": True,
            "available": True,
            "features": ["create", "lifecycle", "delete-owned"],
            "provisioning": True,
        },
    )

    record = host.public_record()
    assert record["online"] is True
    assert record["capabilities"] == {
        "create_vm": True,
        "start": True,
        "stop": True,
        "restart": True,
        "delete": True,
        "console": False,
        "provisioning": True,
        "omarchy_provisioning": False,
    }


def test_remote_unavailable_capabilities_are_not_eligible():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        health=lambda: {"ok": True},
        capabilities=lambda: {"ok": True, "available": False, "features": ["create", "lifecycle"]},
    )

    assert host.public_record()["capabilities"]["create_vm"] is False


def test_remote_host_lifecycle_errors_are_normalized(monkeypatch):
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        lifecycle=lambda *args, **kwargs: (_ for _ in ()).throw(RemoteAgentError("offline")),
    )
    with pytest.raises(VmHostUnavailable):
        host.run_manager("start", "alpha")


def test_remote_claim_preserves_only_safe_agent_error_code():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        claim=lambda *args, **kwargs: (_ for _ in ()).throw(RemoteAgentError(
            "opaque transport text",
            status=422,
            data={"error": {"code": "powershell_direct_failed", "message": "do not reflect"}},
        ))
    )
    with pytest.raises(VmHostUnavailable) as caught:
        host.claim("job-1", "operator", "secret", "one-use")
    assert caught.value.code == "powershell_direct_failed"
    assert "secret" not in str(caught.value)
    assert "do not reflect" not in str(caught.value)


def test_remote_console_retry_accepts_legacy_top_level_safe_code():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        console_credentials=lambda *args, **kwargs: (_ for _ in ()).throw(RemoteAgentError(
            "opaque transport text",
            status=422,
            data={"ok": False, "code": "sunshine_setup_failed", "error": "do not reflect"},
        ))
    )
    with pytest.raises(VmHostUnavailable) as caught:
        host.console_credentials(
            "job-1",
            guest_username="operator",
            guest_password="secret",
            sunshine_username="sunshine",
            sunshine_password="secret",
        )
    assert caught.value.code == "sunshine_setup_failed"
    assert "secret" not in str(caught.value)
    assert "do not reflect" not in str(caught.value)


def test_console_frame_evidence_reaches_the_agent_payload(monkeypatch):
    host = RemoteAgentHost({
        "id": "epic-pc", "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765", "token": "test-token",
    })
    calls = []

    def request(method, path, payload=None, **kwargs):
        calls.append((method, path, payload))
        return {"ok": True, "job": {"state": "ready"}}

    monkeypatch.setattr(host.client, "_request", request)
    metrics = {"nonblackFraction": 0.9, "meanLuma": 70, "stdDev": 42,
               "decodedFramesDelta": 120, "durationMs": 2000}
    result = host.console_complete(
        "job-1", route_prefix="/vm/alpha--epic-pc/", guest_tcp_verified=True,
        video_frame_verified=True, keyboard_input_verified=True,
        mouse_input_verified=True, frame_metrics=metrics,
    )
    assert result["job"]["state"] == "ready"
    assert calls == [("POST", "/v1/provisioning-jobs/job-1/console-complete", {
        "routePrefix": "/vm/alpha--epic-pc/", "guestTcpVerified": True,
        "videoFrameVerified": True, "keyboardInputVerified": True,
        "mouseInputVerified": True, "frameMetrics": metrics,
    })]


def test_remote_vm_url_includes_public_origin_and_host_id(monkeypatch):
    import importlib

    module = importlib.import_module("dashboard.app")
    monkeypatch.setattr(module, "_external_base_url", lambda: "https://techexplore.us")
    assert module._build_vm_url("testre", host_id="epic-pc") == (
        "https://techexplore.us/vm/testre/?host_id=epic-pc"
    )


def test_remote_inventory_gets_public_vm_link(monkeypatch, tmp_path):
    import importlib

    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "testre", "state": "Running"}]

        def normalize_inventory(self, instances):
            return [
                {
                    **item,
                    "placement": "remote",
                    "host_id": self.host_id,
                    "host_name": self.host_name,
                }
                for item in instances
            ]

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    with module.app.test_request_context(
        "/dashboard/api/list",
        headers={
            "Host": "techexplore.us",
            "X-Forwarded-Proto": "https",
            "X-Forwarded-Host": "techexplore.us",
        },
    ):
        items = module.manager_json_list("epic-pc")

    assert items[0]["url"] == "https://techexplore.us/dashboard/console/testre/?host_id=epic-pc"


def test_remote_inventory_not_ready_uses_retrying_console_warmup(monkeypatch, tmp_path):
    import importlib

    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    module = importlib.import_module("dashboard.app")
    monkeypatch.setattr(module, "_external_base_url", lambda: "https://techexplore.us")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "testprov", "state": "Running", "consoleReady": False, "consolePending": True}]

        def normalize_inventory(self, instances):
            return [{**item, "placement": "remote", "host_id": self.host_id, "host_name": self.host_name} for item in instances]

    class FakeRegistry:
        def refresh(self): return None
        def get(self, host_id="local"): return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    with module.app.test_request_context("/dashboard/api/list", headers={"Host": "techexplore.us", "X-Forwarded-Proto": "https", "X-Forwarded-Host": "techexplore.us"}):
        items = module.manager_json_list("epic-pc")
    assert items[0]["url"] == "https://techexplore.us/dashboard/console/testprov/?host_id=epic-pc"


def test_ready_remote_inventory_uses_verified_console_route(monkeypatch, tmp_path):
    import importlib

    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    module = importlib.import_module("dashboard.app")
    monkeypatch.setattr(module, "_external_base_url", lambda: "https://techexplore.us")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"
        def list_vms(self):
            return [{"name": "pilot-14", "state": "Running", "provisioningState": "ready", "consoleReady": True, "consoleRoutePrefix": "/vm/pilot-14/"}]
        def normalize_inventory(self, instances):
            return [{**item, "placement": "remote", "host_id": self.host_id, "host_name": self.host_name} for item in instances]

    class FakeRegistry:
        def refresh(self): return None
        def get(self, host_id="local"): return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    with module.app.test_request_context("/dashboard/api/list", headers={"Host": "techexplore.us", "X-Forwarded-Proto": "https", "X-Forwarded-Host": "techexplore.us"}):
        items = module.manager_json_list("epic-pc")
    assert items[0]["url"] == "https://techexplore.us/vm/pilot-14/?host_id=epic-pc"


def test_hosts_api_redacts_credentials_and_exposes_inventory(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeRegistry:
        config_error = ""

        def refresh(self):
            return None

        def public_records(self):
            return [{
                "id": "epic-pc",
                "display_name": "Epic PC",
                "kind": "remote",
                "provider": "hyperv",
                "agent_url": "http://100.64.0.2:8765",
                "token": "must-not-leak",
                "online": True,
                "capabilities": {"create_vm": True},
            }]

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().get("/dashboard/api/hosts")
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["ok"] is True
    assert payload["hosts"][0]["id"] == "epic-pc"
    assert "token" not in payload["hosts"][0]




def test_authenticated_dashboard_enrollment_uploads_token_without_returning_it(monkeypatch, tmp_path):
    import base64
    import importlib
    import io
    import json
    import stat

    monkeypatch.setenv("BLOBEDASH_USER", "admin")
    monkeypatch.setenv("BLOBEDASH_PASS", "password")
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    monkeypatch.delenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", raising=False)
    module = importlib.import_module("dashboard.app")
    registry_path = tmp_path / "remote-hosts.json"
    module.VM_HOST_REGISTRY.path = registry_path
    module.VM_HOST_REGISTRY._loaded_signature = None
    auth = "Basic " + base64.b64encode(b"admin:password").decode()
    response = module.app.test_client().post(
        "/dashboard/api/remote-hosts/enroll",
        headers={"Authorization": auth},
        data={
            "host_id": "epic-pc",
            "display_name": "Epic PC",
            "agent_url": "http://100.64.0.2:8765",
            "token_file": (io.BytesIO(b"secret-token\n"), "agent.token"),
        },
        content_type="multipart/form-data",
    )
    assert response.status_code == 201
    payload = response.get_json()
    assert payload["ok"] is True
    assert "token" not in payload
    assert "secret-token" not in json.dumps(payload)
    if os.name != "nt":
        assert stat.S_IMODE(registry_path.stat().st_mode) == 0o600
    persisted = json.loads(registry_path.read_text())[0]
    assert "token" not in persisted
    assert persisted["token_enc"].startswith("EV1:")
    assert "secret-token" not in registry_path.read_text()


def test_persisted_plaintext_agent_token_is_rejected(monkeypatch, tmp_path):
    monkeypatch.delenv("EPICVM_ALLOW_PLAINTEXT_REMOTE_HOST_TOKENS", raising=False)
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    path = tmp_path / "remote-hosts.json"
    path.write_text(json.dumps({
        "hosts": [{
            "id": "epic-pc",
            "display_name": "Epic PC",
            "agent_url": "http://100.64.0.2:8765",
            "token": "secret-token",
        }],
    }))
    path.chmod(0o600)
    with pytest.raises(RemoteHostConfigError, match="unencrypted token"):
        load_remote_host_configs(path)


def test_remote_host_enrollment_rejects_unauthenticated_upload(monkeypatch, tmp_path):
    import importlib

    monkeypatch.delenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", raising=False)
    monkeypatch.setenv("BLOBEDASH_USER", "admin")
    monkeypatch.setenv("BLOBEDASH_PASS", "password")
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    module = importlib.import_module("dashboard.app")
    module.VM_HOST_REGISTRY.path = tmp_path / "remote-hosts.json"
    response = module.app.test_client().post(
        "/dashboard/api/remote-hosts/enroll",
        data={"host_id": "epic-pc", "token": "secret-token"},
    )
    assert response.status_code == 401
    assert not module.VM_HOST_REGISTRY.path.exists()


def test_remote_lifecycle_route_uses_selected_host(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")
    calls = []

    class Result:
        returncode = 0
        stdout = ""
        stderr = ""

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def run_manager(self, action, name, **kwargs):
            calls.append((action, name, kwargs))
            return Result()

        def check_call(self, action, name, **kwargs):
            calls.append((action, name, kwargs))

        def list_vms(self):
            return [{"name": "alpha"}]

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().post("/dashboard/api/start/alpha?host_id=epic-pc")
    assert response.status_code == 200
    assert calls and calls[0][0:2] == ("start", "alpha")


def test_remote_host_enrollment_preflight_is_same_origin_only(monkeypatch, tmp_path):
    import importlib

    monkeypatch.delenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", raising=False)
    monkeypatch.setenv("BLOBEDASH_USER", "admin")
    monkeypatch.setenv("BLOBEDASH_PASS", "password")
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    module = importlib.import_module("dashboard.app")
    module.VM_HOST_REGISTRY.path = tmp_path / "remote-hosts.json"
    response = module.app.test_client().options(
        "/dashboard/api/remote-hosts/enroll",
        headers={"Origin": "https://localhost"},
    )
    assert response.status_code == 204
    assert response.headers["Access-Control-Allow-Origin"] == "https://localhost"
    assert response.headers["Access-Control-Allow-Credentials"] == "true"


def test_duplicate_remote_vm_names_fail_closed(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"

        def __init__(self, host_id, names):
            self.host_id = host_id
            self.host_name = host_id
            self._names = names

        def list_vms(self):
            return [{"name": name} for name in self._names]

    selected = FakeHost("epic-pc", ["alpha"])
    other = FakeHost("other-pc", ["alpha"])

    class FakeRegistry:
        providers = {"local": object(), "epic-pc": selected, "other-pc": other}

        def refresh(self):
            return None

        def get(self, host_id="local"):
            return self.providers[host_id]

        def cached_inventory(self, host_id):
            return [{"name": "alpha"}] if host_id == "other-pc" else []

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().post("/dashboard/api/start/alpha?host_id=epic-pc")
    assert response.status_code == 409
    assert response.get_json()["code"] == "ambiguous_vm_owner"


def test_create_rechecks_remote_placement_and_capability(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

        def public_records(self):
            return [{
                "id": "epic-pc",
                "online": False,
                "capabilities": {"create_vm": False},
            }]

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().post(
        "/dashboard/api/create",
        json={"name": "alpha", "placement": "remote", "host_id": "epic-pc"},
    )
    assert response.status_code == 409
    assert response.get_json()["code"] == "host_offline"

    mismatch = module.app.test_client().post(
        "/dashboard/api/create",
        json={"name": "alpha", "placement": "local", "host_id": "epic-pc"},
    )
    assert mismatch.status_code == 400


def test_admin_auth_accepts_hash_and_rejects_plaintext_fallback(monkeypatch):
    import importlib
    from werkzeug.security import generate_password_hash

    module = importlib.import_module("dashboard.app")
    monkeypatch.setenv("BLOBEDASH_USER", "Epic")
    monkeypatch.setenv("BLOBEDASH_PASS", "legacy-password")
    monkeypatch.setenv("BLOBEDASH_PASS_HASH", generate_password_hash("new-password"))

    user, verifier = module._admin_credentials()
    assert user == "Epic"
    assert module._admin_password_matches("new-password", verifier) is True
    assert module._admin_password_matches("legacy-password", verifier) is False


def test_remote_inventory_uses_vm_state_for_dashboard_status():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        health=lambda: {"ok": True},
        capabilities=lambda: {},
    )

    inventory = host.normalize_inventory([{
        "name": "alpha",
        "state": "Off",
        "status": "Operating normally",
    }])

    assert inventory[0]["state"] == "Off"
    assert inventory[0]["status"] == "Off"
    assert inventory[0]["provider_status"] == "Operating normally"
    assert inventory[0]["running"] is False


def test_remote_status_normalizes_nested_vm_state():
    host = RemoteAgentHost({
        "id": "epic-pc",
        "display_name": "Epic PC",
        "agent_url": "http://100.64.0.2:8765",
        "token": "token",
    })
    host.client = SimpleNamespace(
        status=lambda name: {
            "ok": True,
            "vm": {"name": name, "state": "Running", "status": "Operating normally"},
        },
    )

    response = host.status("alpha")

    assert response["vm"]["state"] == "Running"
    assert response["vm"]["status"] == "Running"
    assert response["vm"]["provider_status"] == "Operating normally"
    assert response["vm"]["running"] is True


def test_remote_manage_settings_reads_selected_remote_host(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "alpha"}]

        def status(self, name):
            return {"ok": True, "vm": {"name": name, "id": "vm-1", "state": "Off", "status": "Off", "profile": "gaming"}}

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().get("/dashboard/api/vm-settings/alpha?host_id=epic-pc")

    assert response.status_code == 200
    body = response.get_json()
    assert body["placement"] == "remote"
    assert body["host_id"] == "epic-pc"
    assert body["state"] == "Off"
    assert body["status"] == "Off"
    assert body["vm_id"] == "vm-1"


def test_remote_lifecycle_routes_forward_start_stop_restart_to_selected_host(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")
    calls = []

    class Result:
        returncode = 0
        stdout = ""
        stderr = ""

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "alpha"}]

        def run_manager(self, action, name, **kwargs):
            calls.append(("run_manager", action, name, kwargs))
            return Result()

        def check_call(self, action, name, **kwargs):
            calls.append(("check_call", action, name, kwargs))

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    client = module.app.test_client()

    assert client.post("/dashboard/api/start/alpha?host_id=epic-pc").status_code == 200
    assert client.post("/dashboard/api/stop/alpha?host_id=epic-pc").status_code == 200
    assert client.post("/dashboard/api/restart/alpha?host_id=epic-pc").status_code == 200
    assert [(entry[0], entry[1]) for entry in calls] == [
        ("run_manager", "start"),
        ("run_manager", "stop"),
        ("run_manager", "restart"),
    ]
    assert all(entry[2] == "alpha" for entry in calls)


def test_remote_status_endpoint_flattens_live_state_for_legacy_ui(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "alpha"}]

        def status(self, name):
            return {
                "ok": True,
                "vm": {
                    "name": name,
                    "state": "Running",
                    "status": "Operating normally",
                    "profile": "gaming",
                },
            }

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    response = module.app.test_client().get("/dashboard/api/vm/alpha/status?host_id=epic-pc")

    assert response.status_code == 200
    body = response.get_json()
    assert body["state"] == "Running"
    assert body["status"] == "Running"
    assert body["provider_status"] == "Operating normally"
    assert body["running"] is True
    assert body["vm"]["state"] == "Running"


def test_manager_list_uses_request_host_when_called_without_explicit_host_id(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"
        host_name = "Epic PC"

        def list_vms(self):
            return [{"name": "alpha", "state": "Running"}]

        def normalize_inventory(self, instances):
            return [{
                **item,
                "placement": "remote",
                "host_id": self.host_id,
                "host_name": self.host_name,
            } for item in instances]

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            assert host_id == "epic-pc"
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    with module.app.test_request_context(
        "/dashboard/api/list?host_id=epic-pc",
        headers={"Host": "techexplore.us", "X-Forwarded-Proto": "https", "X-Forwarded-Host": "techexplore.us"},
    ):
        items = module.manager_json_list()

    assert items[0]["url"] == "https://techexplore.us/dashboard/console/alpha/?host_id=epic-pc"


def test_remote_ownership_check_does_not_probe_other_hosts_live(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class SelectedHost:
        kind = "remote"
        host_id = "epic-pc"

        def list_vms(self):
            return [{"name": "alpha"}]

    class DeadOtherHost:
        kind = "remote"

        def list_vms(self):
            raise AssertionError("ownership checks must not fan out to live hosts")

    class Registry:
        providers = {"local": object(), "epic-pc": SelectedHost(), "other-pc": DeadOtherHost()}

        def cached_inventory(self, host_id):
            return []

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", Registry())
    module._ensure_remote_vm_exists(Registry.providers["epic-pc"], "alpha")


def test_remote_manage_settings_stays_out_of_local_runtime_state(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    import importlib

    module = importlib.import_module("dashboard.app")

    class FakeHost:
        kind = "remote"
        host_id = "epic-pc"

        def list_vms(self):
            return [{"name": "alpha"}]

    class FakeRegistry:
        def refresh(self):
            return None

        def get(self, host_id="local"):
            return FakeHost()

    monkeypatch.setattr(module, "VM_HOST_REGISTRY", FakeRegistry())
    monkeypatch.setattr(module, "_set_instance_meta", lambda *args, **kwargs: pytest.fail("remote settings touched local instance metadata"))
    monkeypatch.setattr(module, "_run_manager", lambda *args, **kwargs: pytest.fail("remote settings triggered a local runtime action"))
    response = module.app.test_client().post(
        "/dashboard/api/vm-settings/alpha?host_id=epic-pc",
        json={"host_id": "epic-pc", "title": "should-not-write"},
    )
    assert response.status_code == 200
    payload = response.get_json()
    assert payload["host_id"] == "epic-pc"
    assert payload["title"] == "should-not-write"

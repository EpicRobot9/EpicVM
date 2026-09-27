import json
import pathlib
from types import SimpleNamespace

import pytest

from dashboard.moonlight_orchestrator import MoonlightOrchestrator
import dashboard.moonlight_orchestrator as moonlight_module
from dashboard.guacamole_orchestrator import ConsoleOrchestrationError


IMAGE = "mrcreativ3001/moonlight-web-stream@sha256:" + "a" * 64


def test_multiple_consoles_reserve_disjoint_ports_and_keep_them_on_repair(tmp_path):
    orch = make_orchestrator(tmp_path)
    ranges = []
    for name in ('first', 'second', 'third', 'cloudpc-desktop'):
        target = orch.stage_plan(orch.build_plan(name=name, guest_ip='100.111.82.1'))
        ports = json.loads((target / 'server/config.json').read_text())['webrtc']['port_range']
        current = set(range(ports['min'], ports['max'] + 1))
        assert all(current.isdisjoint(previous) for previous in ranges)
        ranges.append(current)
        assert f'{ports["min"]}-{ports["max"]}:{ports["min"]}-{ports["max"]}/udp' in (target / 'docker-compose.yml').read_text()
    before = orch._staged_webrtc_ports('second')
    (tmp_path / 'second').rename(tmp_path / '.second-retained')
    fresh = make_orchestrator(tmp_path)
    fresh.stage_plan(fresh.build_plan(name='second', guest_ip='100.111.82.1'))
    assert fresh._staged_webrtc_ports('second') == before


def test_port_allocation_respects_legacy_bundles_and_concurrent_reservations(tmp_path):
    from concurrent.futures import ThreadPoolExecutor
    orch = make_orchestrator(tmp_path)
    legacy = tmp_path / 'legacy' / 'server'
    legacy.mkdir(parents=True)
    (legacy / 'config.json').write_text(orch.build_config(name='legacy'))
    def reserve(index):
        return make_orchestrator(tmp_path)._reserve_webrtc_ports(f'new-{index}')
    with ThreadPoolExecutor(max_workers=8) as pool:
        allocated = list(pool.map(reserve, range(16)))
    assert len(set(allocated)) == 16
    assert all(start > 41010 for start, end in allocated)


def make_orchestrator(root, **overrides):
    options = {
        "root": str(root),
        "digests": {"moonlight": IMAGE},
        "tcp_probe": lambda *_: True,
        "disk_probe": lambda: True,
        "route_owner_probe": lambda *_: True,
        "routing_probe": lambda: True,
        "auth_status_probe": lambda *_: True,
        "public_host": "techexplore.us",
        "tls_resolver": "myresolver",
        "auth_middleware": "epicvm-portal-auth@file",
        "router_priority": 600,
    }
    options.update(overrides)
    return MoonlightOrchestrator(**options)


def test_shell_quoted_environment_image_is_accepted(tmp_path, monkeypatch):
    monkeypatch.delenv("EPICVM_MOONLIGHT_IMAGE", raising=False)
    monkeypatch.setenv("EPICVM_MOONLIGHT_IMAGE", f"'{IMAGE}'")
    orch = MoonlightOrchestrator(
        root=str(tmp_path),
        public_host="techexplore.us",
        tls_resolver="myresolver",
        router_priority=600,
        tcp_probe=lambda *_: True,
        disk_probe=lambda: True,
        route_owner_probe=lambda *_: True,
        routing_probe=lambda: True,
        auth_status_probe=lambda *_: True,
    )
    assert orch._image() == IMAGE


def test_plan_is_digest_pinned_path_correct_and_does_not_contain_credentials(tmp_path):
    orch = make_orchestrator(tmp_path)
    plan = orch.build_plan(name="alpha", guest_ip="100.111.82.1")
    config = json.loads(plan.config)
    assert IMAGE in plan.compose
    assert "Host(`techexplore.us`) && PathPrefix(`/vm/alpha/`)" in plan.compose
    assert "middlewares: \"epicvm-alpha-portal-auth,epicvm-alpha-portal-user\"" in plan.compose
    assert "middlewares.epicvm-alpha-portal-auth.forwardauth.address: \"http://blobedash:5000/dashboard/auth/vm/alpha\"" in plan.compose
    assert "middlewares.epicvm-alpha-portal-auth.forwardauth.trustForwardHeader: \"true\"" in plan.compose
    assert "middlewares.epicvm-alpha-portal-user.forwardauth" not in plan.compose
    assert "epicvm-portal-auth@file" not in plan.compose
    assert "url_path_prefix\":\"/vm/alpha\"" in plan.config
    assert config["moonlight"]["pair_device_name"] == "EpicVMWeb"
    assert 'ports:\n      - "41000-41010:41000-41010/udp"' in plan.compose
    assert 'WEBRTC_PORT_RANGE: "41000:41010"' in plan.compose
    assert "WEBRTC_NAT_1TO1_HOST" not in plan.compose
    assert "healthcheck:" in plan.compose
    assert 'test: ["CMD-SHELL", "kill -0 1"]' in plan.compose
    assert "curl -fsS" not in plan.compose
    assert "internal: true" not in plan.compose
    assert "sunshine" not in plan.compose.lower()
    assert "operator" not in plan.compose
    assert "transient-password" not in plan.compose + plan.config + plan.data


def test_plan_advertises_configured_nat_host_and_udp_range(tmp_path):
    orch = make_orchestrator(tmp_path, webrtc_nat_host="100.89.87.98")
    plan = orch.build_plan(name="alpha", guest_ip="100.111.82.1")
    config = json.loads(plan.config)
    assert config["webrtc"]["nat_1to1"] == {"ice_candidate_type": "host", "ips": ["100.89.87.98"]}
    assert 'WEBRTC_NAT_1TO1_HOST: "100.89.87.98"' in plan.compose
    assert '41000-41010:41000-41010/udp' in plan.compose


def test_plan_accepts_public_nat_host_for_internet_clients(tmp_path):
    orch = make_orchestrator(tmp_path, webrtc_nat_host="72.60.29.204")
    plan = orch.build_plan(name="alpha", guest_ip="100.111.82.1")
    config = json.loads(plan.config)
    assert config["webrtc"]["nat_1to1"] == {"ice_candidate_type": "host", "ips": ["72.60.29.204"]}
    assert 'WEBRTC_NAT_1TO1_HOST: "72.60.29.204"' in plan.compose


@pytest.mark.parametrize("address", ["127.0.0.1", "169.254.1.2", "192.168.1.10", "224.0.0.1"])
def test_rejects_non_routable_nat_host_outside_tailnet(tmp_path, address):
    with pytest.raises(ConsoleOrchestrationError) as failure:
        make_orchestrator(tmp_path, webrtc_nat_host=address)
    assert failure.value.code == "invalid_moonlight_nat_host"


def test_turn_credentials_are_written_only_to_config(tmp_path, monkeypatch):
    monkeypatch.setenv("EPICVM_MOONLIGHT_TURN_URLS", "turns:relay.example:5349,turn:relay.example:3478")
    monkeypatch.setenv("EPICVM_MOONLIGHT_TURN_USERNAME", "turn-user")
    monkeypatch.setenv("EPICVM_MOONLIGHT_TURN_CREDENTIAL", "turn-secret")

    plan = make_orchestrator(tmp_path).build_plan(name="alpha", guest_ip="100.111.82.1")
    servers = json.loads(plan.config)["webrtc"]["ice_servers"]
    assert servers[-1] == {
        "urls": ["turns:relay.example:5349", "turn:relay.example:3478"],
        "username": "turn-user",
        "credential": "turn-secret",
    }
    assert "turn-user" not in plan.compose
    assert "turn-secret" not in plan.compose


@pytest.mark.parametrize("variable", [
    "EPICVM_MOONLIGHT_TURN_URLS",
    "EPICVM_MOONLIGHT_TURN_USERNAME",
    "EPICVM_MOONLIGHT_TURN_CREDENTIAL",
])
def test_incomplete_turn_configuration_fails_closed(tmp_path, monkeypatch, variable):
    for name in (
        "EPICVM_MOONLIGHT_TURN_URLS",
        "EPICVM_MOONLIGHT_TURN_USERNAME",
        "EPICVM_MOONLIGHT_TURN_CREDENTIAL",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv(variable, "turn:relay.example:3478" if variable.endswith("URLS") else "configured")

    with pytest.raises(ConsoleOrchestrationError) as failure:
        make_orchestrator(tmp_path)
    assert failure.value.code == "moonlight_turn_config_required"


def test_dashboard_installers_use_init_and_protected_turn_env_file():
    install = pathlib.Path("server/install.sh").read_text(encoding="utf-8")
    ensure = pathlib.Path("server/blobedash-ensure.sh").read_text(encoding="utf-8")
    assert "docker run -d --name blobedash --init --restart unless-stopped" in install
    assert 'docker run -d --name "$NAME" --init --restart unless-stopped' in ensure
    assert "--env-file /opt/blobe-vm/.env" in install
    assert '--env-file "$ENV_FILE"' in ensure
    assert "chmod 600 /opt/blobe-vm/.env" in install
    assert 'chmod 600 "$ENV_FILE"' in ensure
    for text in (install, ensure):
        assert "-e EPICVM_MOONLIGHT_TURN_CREDENTIAL" not in text


def test_cloudpc_and_vm_plans_use_disjoint_webrtc_udp_ranges(tmp_path):
    orch = make_orchestrator(tmp_path)
    vm = orch.build_plan(name="alpha", guest_ip="100.111.82.1")
    cloudpc = orch.build_plan(name="cloudpc-epic-a1", guest_ip="100.111.82.2")

    vm_config = json.loads(vm.config)["webrtc"]["port_range"]
    cloudpc_config = json.loads(cloudpc.config)["webrtc"]["port_range"]
    assert vm_config == {"min": 41000, "max": 41010}
    assert cloudpc_config == {"min": 41011, "max": 41021}
    assert set(range(vm_config["min"], vm_config["max"] + 1)).isdisjoint(
        range(cloudpc_config["min"], cloudpc_config["max"] + 1)
    )
    assert '41011-41021:41011-41021/udp' in cloudpc.compose


def test_native_seat_uses_its_own_apollo_port_without_changing_vm_default(tmp_path):
    probed = []
    orch = make_orchestrator(tmp_path, tcp_probe=lambda host, port, timeout: probed.append(port) or True)
    seat = orch.build_plan(name='seat-owner', guest_ip='100.111.82.1', sunshine_port=48130)
    vm = orch.build_plan(name='gaming-vm', guest_ip='100.111.82.2')
    assert probed[:2] == [48130, 48131]
    assert json.loads(seat.config)['moonlight']['default_http_port'] == 48130
    assert json.loads(vm.config)['moonlight']['default_http_port'] == 47989
    target = orch.stage_plan(seat)
    assert json.loads((target / 'plan.json').read_text())['sunshinePort'] == 48130


def test_remote_plan_can_use_host_scoped_route_without_changing_vm_name(tmp_path):
    orch = make_orchestrator(tmp_path)
    plan = orch.build_plan(name="testprovvm", guest_ip="100.111.82.1", route_name="testprovvm--epic-pc")
    assert plan.name == "testprovvm"
    assert plan.route_prefix == "/vm/testprovvm--epic-pc/"
    assert "PathPrefix(`/vm/testprovvm--epic-pc/`)" in plan.compose
    assert json.loads(plan.config)["web_server"]["url_path_prefix"] == "/vm/testprovvm--epic-pc"
    assert "dashboard/auth/vm/testprovvm" in plan.compose


def test_staging_writes_only_safe_owned_metadata(tmp_path):
    orch = make_orchestrator(tmp_path)
    target = orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    assert target == tmp_path / "alpha"
    assert (target / "server" / "config.json").is_file()
    assert (target / "server" / "data.json").is_file()
    plan = json.loads((target / "plan.json").read_text())
    assert plan == {"owner": "EpicVM", "version": 1, "backend": "moonlight", "name": "alpha", "guestIp": "100.111.82.1", "sunshinePort": 47989, "routePrefix": "/vm/alpha/", "paired": False}
    assert list(target.rglob("*"))


def test_stage_plan_chowns_paths_after_atomic_rename(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(moonlight_module.os, "chown", lambda path, uid, gid: calls.append(pathlib.Path(path)), raising=False)
    orch = make_orchestrator(tmp_path)
    target = orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    assert target / "server" in calls
    assert target / "server" / "config.json" in calls
    assert target / "server" / "data.json" in calls
    assert not any(path.name.startswith(".alpha-") for path in calls)


def test_runtime_isolation_accepts_only_expected_udp_bindings(tmp_path):
    expected_bindings = {
        f"{port}/udp": [{"HostIp": "", "HostPort": str(port)}]
        for port in range(41000, 41011)
    }

    def inspect(args, **_kwargs):
        if args[1:3] == ["ps", "--filter"]:
            return SimpleNamespace(stdout="container-id")
        return SimpleNamespace(stdout=json.dumps([{
            "Config": {"Labels": {"com.docker.compose.service": "moonlight-web"}},
            "HostConfig": {"PortBindings": expected_bindings},
            "NetworkSettings": {"Networks": {"proxy": {}, "gaming_egress": {}}},
        }]))

    orch = make_orchestrator(tmp_path, command_runner=inspect)
    orch.stage_plan(orch.build_plan(name='alpha', guest_ip='100.111.82.1'))
    assert orch._runtime_isolated("alpha") is True

    expected_bindings["8080/tcp"] = [{"HostIp": "", "HostPort": "8080"}]
    assert orch._runtime_isolated("alpha") is False


def test_runtime_isolation_rejects_missing_udp_bindings(tmp_path):
    def inspect(args, **_kwargs):
        if args[1:3] == ["ps", "--filter"]:
            return SimpleNamespace(stdout="container-id")
        return SimpleNamespace(stdout=json.dumps([{
            "Config": {"Labels": {"com.docker.compose.service": "moonlight-web"}},
            "HostConfig": {"PortBindings": {}},
            "NetworkSettings": {"Networks": {"proxy": {}, "gaming_egress": {}}},
        }]))

    orch = make_orchestrator(tmp_path, command_runner=inspect)
    assert orch._runtime_isolated("alpha") is False


def test_internal_api_url_includes_configured_vm_prefix(tmp_path):
    orch = make_orchestrator(tmp_path)

    def inspect(args, **_kwargs):
        if args[1:3] == ["ps", "--filter"]:
            return SimpleNamespace(stdout="container-id")
        return SimpleNamespace(stdout=json.dumps([{"NetworkSettings": {"Networks": {"proxy": {"IPAddress": "172.20.0.2"}}}}]))

    orch.command_runner = inspect
    assert orch._container_url("alpha") == "http://172.20.0.2:8080/vm/alpha"


def test_pairing_keeps_sunshine_secret_out_of_bundle(tmp_path):
    calls = []

    class Response:
        def __init__(self, lines=(), payload=b""):
            self.lines = [line if isinstance(line, bytes) else str(line).encode() for line in lines]
            self.payload = payload

        def readline(self):
            return self.lines.pop(0) if self.lines else b""

        def read(self, *_args):
            if self.payload:
                return self.payload
            return b"\n".join(self.lines)

        def close(self):
            return None

    def http(method, url, *, headers, body, timeout):
        calls.append((method, url, headers, body))
        if url.endswith("/api/hosts"):
            return Response(payload=(json.dumps({"host_id": "other-host", "paired": "Paired"}) + "\n").encode())
        if "/api/host?" in url or url.endswith("/api/host"):
            return Response(payload=json.dumps({"host": {"host_id": "1251941260"}}).encode())
        if url.endswith("/api/pair"):
            return Response([json.dumps({"Pin": "1234"}), json.dumps({"Paired": "Paired"})])
        if url.endswith("/api/pin"):
            return Response(payload=b'{"status":true}')
        raise AssertionError(url)

    orch = make_orchestrator(tmp_path, http_request=http)
    orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    orch._container_url = lambda _name, _route_prefix=None: "http://172.20.0.2:8080/vm/alpha"
    result = orch.pair_staged("alpha", sunshine_username="sunshine-user", sunshine_password="secret-value")
    assert result["paired"] is True
    pair = next(call for call in calls if call[1].endswith("/api/pair"))
    pair_payload = json.loads(pair[3].decode())
    assert isinstance(pair_payload["host_id"], int)
    assert pair_payload["host_id"] == 1251941260
    contents = "".join(path.read_text(errors="ignore") for path in tmp_path.rglob("*") if path.is_file())
    assert "secret-value" not in contents
    assert "sunshine-user" not in contents
    sunshine = next(call for call in calls if call[1].endswith("/api/pin"))
    assert "secret-value" not in sunshine[3].decode()
    assert sunshine[2]["Authorization"].startswith("Basic ")
    assert json.loads(sunshine[3].decode())["name"] == "EpicVMWeb"
    assert json.loads((tmp_path / "alpha" / "plan.json").read_text())["paired"] is True


def test_pairing_refuses_to_mark_plan_ready_when_authenticated_host_query_fails(tmp_path):
    class Response:
        def __init__(self, lines=(), payload=b""):
            self.lines = [line if isinstance(line, bytes) else str(line).encode() for line in lines]
            self.payload = payload

        def readline(self):
            return self.lines.pop(0) if self.lines else b""

        def read(self, *_args):
            return self.payload or b"\n".join(self.lines)

        def close(self):
            return None

    def http(method, url, *, headers, body, timeout):
        if url.endswith("/api/hosts"):
            return Response(payload=b'{"hosts":[]}')
        if url.endswith("/api/host"):
            return Response(payload=b'{"host":{"host_id":1251941260}}')
        if "/api/host?host_id=" in url:
            return Response(payload=b'{"error":"certificate rejected"}')
        if url.endswith("/api/pair"):
            return Response([b'{"Pin":"1234"}', b'{"Paired":"Paired"}'])
        if url.endswith("/api/pin"):
            return Response(payload=b'{"status":true}')
        raise AssertionError(url)

    orch = make_orchestrator(tmp_path, http_request=http)
    orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    orch._container_url = lambda _name, _route_prefix=None: "http://172.20.0.2:8080/vm/alpha"

    with pytest.raises(ConsoleOrchestrationError) as failure:
        orch.pair_staged("alpha", sunshine_username="sunshine-user", sunshine_password="secret-value")

    assert failure.value.code == "moonlight_host_failed"
    assert json.loads((tmp_path / "alpha" / "plan.json").read_text())["paired"] is False


def test_repair_rebuilds_bundle_and_requires_authenticated_host_query(tmp_path):
    calls = []

    class Response:
        def __init__(self, lines=(), payload=b""):
            self.lines = [line if isinstance(line, bytes) else str(line).encode() for line in lines]
            self.payload = payload

        def readline(self):
            return self.lines.pop(0) if self.lines else b""

        def read(self, *_args):
            return self.payload or b"\n".join(self.lines)

        def close(self):
            return None

    def http(method, url, *, headers, body, timeout):
        calls.append((method, url))
        if url.endswith("/api/hosts"):
            return Response(payload=b'{"hosts":[]}')
        if url.endswith("/api/host"):
            return Response(payload=b'{"host":{"host_id":1251941260}}')
        if "/api/host?host_id=" in url:
            return Response(payload=b'{"host":{"host_id":1251941260}}')
        if url.endswith("/api/pair"):
            return Response([b'{"Pin":"1234"}', b'{"Paired":"Paired"}'])
        if url.endswith("/api/pin"):
            return Response(payload=b'{"status":true}')
        raise AssertionError(url)

    orch = make_orchestrator(
        tmp_path,
        http_request=http,
        route_owner_probe=lambda _route: not (tmp_path / "alpha").exists(),
    )
    orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    orch._container_url = lambda _name, _route_prefix=None: "http://172.20.0.2:8080/vm/alpha"
    orch.start_staged = lambda _name: {"ok": True, "routePrefix": "/vm/alpha--epic-pc/", "guestTcpVerified": True}
    result = orch.repair_staged(
        "alpha",
        guest_ip="100.111.82.1",
        route_name="alpha--epic-pc",
        sunshine_username="sunshine-user",
        sunshine_password="secret-value",
    )

    assert result["ok"] is True
    assert result["repaired"] is True
    assert result["quarantined"] is True
    assert any("/api/host?host_id=" in url for _, url in calls)
    plan = json.loads((tmp_path / "alpha" / "plan.json").read_text())
    assert plan["paired"] is True
    assert "secret-value" not in (tmp_path / "alpha" / "plan.json").read_text()


def test_verify_staged_requires_authenticated_host_details(tmp_path):
    calls = []

    class Response:
        def __init__(self, payload=b""):
            self.payload = payload

        def read(self, *_args):
            return self.payload

        def close(self):
            return None

    def http(method, url, *, headers, body, timeout):
        calls.append((method, url))
        if url.endswith("/api/hosts"):
            return Response(payload=b'{"hosts":[{"address":"100.111.82.1","http_port":47989,"host_id":"1251941260"}]}')
        if "/api/host?host_id=" in url:
            return Response(payload=b'{"host":{"host_id":"1251941260"}}')
        raise AssertionError(url)

    orch = make_orchestrator(tmp_path, http_request=http)
    orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1", route_name="alpha--epic-pc"))
    plan_path = tmp_path / "alpha" / "plan.json"
    plan = json.loads(plan_path.read_text())
    plan["paired"] = True
    plan_path.write_text(json.dumps(plan))
    orch._container_url = lambda _name, _route_prefix=None: "http://172.20.0.2:8080/vm/alpha--epic-pc"

    result = orch.verify_staged("alpha", guest_ip="100.111.82.1", route_name="alpha--epic-pc")

    assert result["healthy"] is True
    assert result["guestTcpVerified"] is True
    assert any("/api/host?host_id=1251941260" in url for _, url in calls)


def test_repair_preserves_existing_bundle_when_guest_tcp_is_unavailable(tmp_path):
    orch = make_orchestrator(tmp_path)
    target = orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    orch.tcp_probe = lambda *_: False

    with pytest.raises(ConsoleOrchestrationError) as failure:
        orch.repair_staged(
            "alpha",
            guest_ip="100.111.82.1",
            route_name="alpha--epic-pc",
            sunshine_username="sunshine-user",
            sunshine_password="secret-value",
        )

    assert failure.value.code == "sunshine_tcp_unavailable"
    assert target.exists()
    assert not list(tmp_path.glob(".quarantine-*"))


def test_repair_rolls_back_old_bundle_when_replacement_fails(tmp_path):
    orch = make_orchestrator(tmp_path)
    target = orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    old_plan = json.loads((target / "plan.json").read_text())
    old_plan["paired"] = True
    (target / "plan.json").write_text(json.dumps(old_plan))
    starts = []

    def start(name):
        starts.append(name)
        if len(starts) == 1:
            raise ConsoleOrchestrationError("replacement failed", status=502, code="console_start_failed")
        return {"ok": True, "routePrefix": "/vm/alpha--epic-pc/", "guestTcpVerified": True}

    orch.start_staged = start
    orch.stop_staged = lambda _name: None

    with pytest.raises(ConsoleOrchestrationError) as failure:
        orch.repair_staged(
            "alpha",
            guest_ip="100.111.82.1",
            route_name="alpha--epic-pc",
            sunshine_username="sunshine-user",
            sunshine_password="secret-value",
        )

    assert failure.value.code == "console_start_failed"
    assert starts == ["alpha", "alpha"]
    assert target.exists()
    assert json.loads((target / "plan.json").read_text()) == old_plan
    assert not list((tmp_path / "quarantine").glob("alpha-*/plan.json"))


def test_sunshine_pair_retries_when_sunshine_reports_pending_session(tmp_path):
    calls = []
    pin_responses = [
        {"status": False},
        {"status": "true"},
    ]

    class Response:
        def __init__(self, payload):
            self.payload = json.dumps(payload).encode("utf-8")

        def read(self, *_args):
            return self.payload

        def close(self):
            return None

    def http(method, url, *, headers, body, timeout):
        calls.append((method, url, headers, body, timeout))
        if url.endswith("/api/hosts"):
            return Response({"hosts": []})
        if url.endswith("/api/host"):
            return Response({"host": {"host_id": "1251941260"}})
        if url.endswith("/api/pair"):
            return Response({"Pin": "1234"})
        if url.endswith("/api/pin"):
            return Response(pin_responses.pop(0))
        raise AssertionError(url)

    orch = make_orchestrator(tmp_path, http_request=http)
    orch.stage_plan(orch.build_plan(name="alpha", guest_ip="100.111.82.1"))
    orch._sunshine_pair("100.111.82.1", "sunshine-user", "secret-value", "1234", "alpha")
    pin_calls = [call for call in calls if call[1].endswith("/api/pin")]
    assert len(pin_calls) == 2


def test_invalid_guest_and_missing_digest_fail_closed(tmp_path):
    with pytest.raises(ConsoleOrchestrationError) as guest:
        make_orchestrator(tmp_path).build_plan(name="alpha", guest_ip="192.168.1.3")
    assert guest.value.code == "invalid_guest_ip"
    with pytest.raises(ConsoleOrchestrationError) as digest:
        make_orchestrator(tmp_path, digests={"moonlight": ""}).build_compose(name="alpha")
    assert digest.value.code == "digest_required"

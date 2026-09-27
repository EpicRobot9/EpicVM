import importlib.util
import json
from pathlib import Path
import sys

import pytest


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("host_direct_supervisor", SCRIPTS / "supervise_host_direct_streams.py")
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)


def test_udp_allocator_skips_unbindable_and_reserved_ranges(monkeypatch, tmp_path):
    monkeypatch.setattr(supervisor, "_media_firewall_ready", lambda: True, raising=False)
    for name, lo in (("other-seat", 40900), ("other-vm", 40922)):
        server = tmp_path / name / "server"
        server.mkdir(parents=True)
        (server / "config.json").write_text(json.dumps({"webrtc": {"port_range": {"min": lo, "max": lo + 10}}}))
    monkeypatch.setattr(supervisor, "_udp_range_bindable", lambda start: start != 40911)
    assert supervisor._allocate_udp_range(tmp_path) == 40933


def test_pairing_refresh_keeps_healthy_seat_untouched(monkeypatch, tmp_path):
    local = tmp_path / "seat-" / "server"
    local.mkdir(parents=True)
    path = local / "data.json"
    path.write_text(json.dumps({"hosts": {"123": {"address": "127.0.0.1", "http_port": 48100,
                                                  "pair_info": {"client_certificate": "old"}}}}))
    monkeypatch.setattr(supervisor, "_seat_host_healthy", lambda *args: True)
    monkeypatch.setattr(supervisor, "_stop_instance", lambda *args: pytest.fail("healthy seat stopped"))
    assert supervisor._refresh_seat_pairing(tmp_path, "seat-", 8084,
                                            {"hosts": {"456": {"address": "100.72.220.117", "http_port": 48100,
                                                               "pair_info": {"client_certificate": "new"}}}}) is False
    assert json.loads(path.read_text())["hosts"]["123"]["pair_info"]["client_certificate"] == "old"


def test_pairing_refresh_repairs_failed_host_and_preserves_public_id(monkeypatch, tmp_path):
    local = tmp_path / "seat-" / "server"
    local.mkdir(parents=True)
    path = local / "data.json"
    path.write_text(json.dumps({"hosts": {"123": {"address": "127.0.0.1", "http_port": 48100,
                                                  "pair_info": {"client_certificate": "old"}}}}))
    checks = iter((False, True))
    monkeypatch.setattr(supervisor, "_seat_host_healthy", lambda *args: next(checks))
    calls = []
    monkeypatch.setattr(supervisor, "_stop_instance", lambda port: calls.append(("stop", port)))
    monkeypatch.setattr(supervisor, "_start_instance", lambda root, route, port: calls.append(("start", port)))
    assert supervisor._refresh_seat_pairing(tmp_path, "seat-", 8084,
                                            {"hosts": {"456": {"address": "100.72.220.117", "http_port": 48100,
                                                               "pair_info": {"client_certificate": "new"}}}}) is True
    assert list(json.loads(path.read_text())["hosts"]) == ["123"]
    assert calls == [("stop", 8084), ("start", 8084)]
    assert list(local.glob("data.json.before-pair-refresh-*"))


def test_pairing_refresh_rolls_back_when_new_certificate_fails(monkeypatch, tmp_path):
    local = tmp_path / "seat-" / "server"
    local.mkdir(parents=True)
    path = local / "data.json"
    original = {"hosts": {"123": {"address": "127.0.0.1", "http_port": 48100,
                                  "pair_info": {"client_certificate": "old"}}}}
    path.write_text(json.dumps(original))
    monkeypatch.setattr(supervisor, "_seat_host_healthy", lambda *args: False)
    monkeypatch.setattr(supervisor, "_stop_instance", lambda *args: None)
    monkeypatch.setattr(supervisor, "_start_instance", lambda *args: None)
    monkeypatch.setattr(supervisor.time, "sleep", lambda *args: None)
    with pytest.raises(RuntimeError, match="failed authenticated host verification"):
        supervisor._refresh_seat_pairing(tmp_path, "seat-", 8084,
                                         {"hosts": {"456": {"address": "100.72.220.117", "http_port": 48100,
                                                            "pair_info": {"client_certificate": "new"}}}})
    assert json.loads(path.read_text()) == original


def test_pairing_refresh_defers_while_seat_has_active_client(monkeypatch, tmp_path):
    local = tmp_path / "seat-" / "server"
    local.mkdir(parents=True)
    path = local / "data.json"
    path.write_text(json.dumps({"hosts": {"123": {"address": "127.0.0.1", "http_port": 48100,
                                                  "pair_info": {"client_certificate": "old"}}}}))
    monkeypatch.setattr(supervisor, "_seat_host_healthy", lambda *args: False)
    monkeypatch.setattr(supervisor, "_seat_has_active_client", lambda *args: True, raising=False)
    monkeypatch.setattr(supervisor, "_stop_instance", lambda *args: pytest.fail("active seat stopped"))
    assert supervisor._refresh_seat_pairing(tmp_path, "seat-", 8084,
                                            {"hosts": {"456": {"http_port": 48100,
                                                               "pair_info": {"client_certificate": "new"}}}}) is False
    assert json.loads(path.read_text())["hosts"]["123"]["pair_info"]["client_certificate"] == "old"


def test_prestart_udp_reallocation_keeps_existing_valid_range(monkeypatch, tmp_path):
    server = tmp_path / "seat-" / "server"
    server.mkdir(parents=True)
    path = server / "config.json"
    path.write_text(json.dumps({"webrtc": {"port_range": {"min": 40900, "max": 40910}}}))
    monkeypatch.setattr(supervisor, "_udp_range_bindable", lambda start: start == 40900)
    assert supervisor._ensure_seat_udp_range(tmp_path, "seat-") is False
    assert not list(server.glob("config.json.before-udp-refresh-*"))


def test_prestart_udp_reallocation_backs_up_blocked_range(monkeypatch, tmp_path):
    monkeypatch.setattr(supervisor, "_media_firewall_ready", lambda: True, raising=False)
    server = tmp_path / "seat-" / "server"
    server.mkdir(parents=True)
    path = server / "config.json"
    path.write_text(json.dumps({"webrtc": {"port_range": {"min": 40022, "max": 40032}}}))
    monkeypatch.setattr(supervisor, "_udp_range_bindable", lambda start: start != 40022)
    assert supervisor._ensure_seat_udp_range(tmp_path, "seat-") is True
    assert json.loads(path.read_text())["webrtc"]["port_range"] == {"min": 40900, "max": 40910}
    assert list(server.glob("config.json.before-udp-refresh-*"))


def test_udp_allocator_fails_closed_without_media_firewall(monkeypatch, tmp_path):
    monkeypatch.setattr(supervisor, "_media_firewall_ready", lambda: False, raising=False)
    with pytest.raises(RuntimeError, match="media firewall"):
        supervisor._allocate_udp_range(tmp_path)

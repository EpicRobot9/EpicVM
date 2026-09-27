import importlib.util
import os
import sys
import json
import stat

import pytest

# Load the module directly. It uses relative imports (from .moonlight_orchestrator),
# so add its directory to sys.path like the existing app.py test harness does.
_DASHBOARD_DIR = os.path.join(os.path.dirname(__file__), "..", "dashboard")
sys.path.insert(0, os.path.abspath(_DASHBOARD_DIR))
_PATH = os.path.join(_DASHBOARD_DIR, "cloud_pc.py")
_spec = importlib.util.spec_from_file_location("cloud_pc_test_mod", _PATH)
cp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cp)


def test_validate_tailnet_ip_ok():
    assert cp.validate_tailnet_ip("100.72.10.5") == "100.72.10.5"


@pytest.mark.parametrize("bad", ["8.8.8.8", "192.168.1.10", "10.0.0.1", "not-an-ip", "1.2.3.4"])
def test_validate_tailnet_ip_rejects_non_cgnat(bad):
    with pytest.raises(cp.CloudPcConfigError):
        cp.validate_tailnet_ip(bad)


def test_id_format_rejected():
    with pytest.raises(cp.CloudPcConfigError):
        cp.upsert_cloud_pc({"id": "Bad ID", "owner": "epic", "tailnet_ip": "100.72.10.5"}, path="/tmp/none.json")


def test_upsert_and_load(tmp_path):
    path = tmp_path / "cloud-pcs.json"
    rec = cp.upsert_cloud_pc(
        {"id": "cloudpc-epic-a1", "display_name": "My Rig", "owner": "epic", "tailnet_ip": "100.72.10.5"},
        path=str(path),
    )
    assert rec["id"] == "cloudpc-epic-a1"
    assert rec["paired"] is False
    loaded = cp.load_cloud_pcs(path=str(path))
    assert len(loaded) == 1
    assert loaded[0]["owner"] == "epic"
    assert loaded[0]["tailnet_ip"] == "100.72.10.5"
    if os.name != "nt":
        # Registry must be 0600 on POSIX systems. Windows does not expose the
        # same group/world mode bits through stat, so the same chmod call is
        # still exercised but cannot be asserted portably.
        mode = stat.S_IMODE(os.stat(path).st_mode)
        assert mode == 0o600


def test_upsert_is_idempotent_on_id(tmp_path):
    path = tmp_path / "cloud-pcs.json"
    cp.upsert_cloud_pc({"id": "cloudpc-epic-a1", "owner": "epic", "tailnet_ip": "100.72.10.5"}, path=str(path))
    cp.upsert_cloud_pc({"id": "cloudpc-epic-a1", "display_name": "Renamed", "owner": "epic", "tailnet_ip": "100.72.10.5"}, path=str(path))
    assert len(cp.load_cloud_pcs(path=str(path))) == 1
    assert cp.load_cloud_pc("cloudpc-epic-a1", path=str(path))["display_name"] == "Renamed"


def test_is_cloudpc_and_delete(tmp_path):
    path = tmp_path / "cloud-pcs.json"
    cp.upsert_cloud_pc({"id": "cloudpc-epic-a1", "owner": "epic", "tailnet_ip": "100.72.10.5"}, path=str(path))
    assert cp.is_cloudpc("cloudpc-epic-a1", path=str(path)) is True
    assert cp.delete_cloud_pc("cloudpc-epic-a1", path=str(path)) is True
    assert cp.is_cloudpc("cloudpc-epic-a1", path=str(path)) is False
    assert cp.delete_cloud_pc("cloudpc-epic-a1", path=str(path)) is False


def test_generate_id_unique():
    a = cp.generate_cloudpc_id("epic")
    b = cp.generate_cloudpc_id("epic")
    assert a.startswith("cloudpc-epic-")
    assert cp.ID_RE.fullmatch(a)
    assert a != b


def test_create_record_only_no_proxy(tmp_path, monkeypatch):
    """create_cloudpc must NOT stage a proxy (no MoonlightOrchestrator calls)."""
    calls = []

    class FakeOrch:
        def build_plan(self, **k):
            calls.append("build_plan")
            raise AssertionError("proxy should not be staged on create")

        def stage_plan(self, plan):
            calls.append("stage_plan")

        def start_staged(self, n):
            calls.append("start_staged")

        def pair_staged(self, n, **k):
            calls.append("pair_staged")

    monkeypatch.setattr(cp, "_orchestrator", lambda: FakeOrch())
    rec = cp.create_cloudpc(owner="epic", display_name="My Rig", tailnet_ip="100.72.10.5")
    assert rec["id"].startswith("cloudpc-epic-")
    assert rec["paired"] is False
    assert calls == [], f"unexpected orchestrator calls: {calls}"


def test_status_when_proxy_offline(tmp_path, monkeypatch):
    monkeypatch.setattr(cp, "_orchestrator", lambda: _FakeOrch(proxy_up=False))
    monkeypatch.setattr(cp, "_tcp", lambda *a, **k: False)
    st = cp.cloudpc_status("cloudpc-epic-a1", tailnet_ip="100.72.10.5")
    assert st["readiness"] == "stopped"
    assert st["running"] is False
    assert st["type"] == "cloudpc"


def test_status_provisioning_when_proxy_up_unpaired(tmp_path, monkeypatch):
    monkeypatch.setattr(cp, "_orchestrator", lambda: _FakeOrch(proxy_up=True))
    monkeypatch.setattr(cp, "_tcp", lambda *a, **k: True)  # sunshine reachable
    st = cp.cloudpc_status("cloudpc-epic-a1", tailnet_ip="100.72.10.5")
    # proxy up + sunshine up + not paired -> provisioning
    assert st["readiness"] == "provisioning"


def test_status_ready_when_paired(tmp_path, monkeypatch):
    monkeypatch.setattr(cp, "_orchestrator", lambda: _FakeOrch(proxy_up=True))
    monkeypatch.setattr(cp, "_tcp", lambda *a, **k: True)
    monkeypatch.setattr(cp, "load_cloud_pc", lambda n, path=None: {"id": n, "paired": True})
    st = cp.cloudpc_status("cloudpc-epic-a1", tailnet_ip="100.72.10.5")
    assert st["readiness"] == "ready"
    assert st["running"] is True


class _FakeOrch:
    def __init__(self, proxy_up=False):
        self._proxy_up = proxy_up

    def _runtime_isolated(self, name):
        return self._proxy_up

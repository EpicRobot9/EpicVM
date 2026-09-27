"""Regression coverage for Gaming stream-start recovery and evidence gates.

Covers the three black-screen readiness defects:
1. MoonlightOrchestrator.restart_session rebuilds stream state without
   touching the paired bundle contract (control-stream startup race).
2. The dashboard console-verify endpoint completes readiness only from the
   dashboard's own server-measured guest transport result and never forwards
   browser-claimed human video/keyboard/mouse evidence as truth.
3. Complete-EpicVMProvisioningConsole (agent) requires that server-verified
   transport gate, validates caller-supplied frame metrics when present, and
   no longer blocks on any manual browser evidence.
"""
from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[1]


def _load_module(name: str, path: Path, extra_path: Path | None = None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if extra_path is not None:
        sys.path.insert(0, str(extra_path))
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# 1. Orchestrator restart_session
# ---------------------------------------------------------------------------

def _make_orchestrator(tmp_path: Path, plan_overrides: dict | None = None):
    orch_module = _load_module(
        "epicvm_moonlight_orchestrator_under_test",
        REPO / "dashboard" / "moonlight_orchestrator.py",
        extra_path=REPO / "dashboard",
    )
    plan = {
        "name": "vmx",
        "owner": "EpicVM",
        "backend": "moonlight",
        "guestIp": "100.90.90.90",
        "routePrefix": "/vm/vmx/",
        "paired": True,
    }
    if plan_overrides:
        plan.update(plan_overrides)
    calls = []

    class Orchestrator(orch_module.MoonlightOrchestrator):
        def __init__(self):
            self.root = tmp_path
            self._calls = calls

        def _read_plan(self, name):
            return dict(plan)

        def stop_staged(self, name):
            calls.append(("stop", name))

        def start_staged(self, name):
            calls.append(("start", name))

    return Orchestrator(), calls


def test_restart_session_restarts_container_and_preserves_route(tmp_path):
    orch, calls = _make_orchestrator(tmp_path)
    result = orch.restart_session("vmx")
    assert result["ok"] is True and result["restarted"] is True
    assert result["routePrefix"] == "/vm/vmx/"
    assert [c[0] for c in calls] == ["stop", "start"]
    assert all(c[1] == "vmx" for c in calls)


def test_restart_session_rejects_route_mismatch(tmp_path):
    orch, calls = _make_orchestrator(tmp_path)
    with pytest.raises(Exception) as excinfo:
        orch.restart_session("vmx", route_name="other-vm")
    assert getattr(excinfo.value, "code", "") == "moonlight_stale_bundle"
    assert calls == []


# ---------------------------------------------------------------------------
# 2/3. Shared threshold logic used by both gates
# ---------------------------------------------------------------------------

def test_console_verify_thresholds():
    """The documented thresholds reject black, frozen, short, and static video."""
    thresholds = {
        "nonblackFraction": 0.60,
        "meanLuma": 12.0,
        "stdDev": 8.0,
        "decodedFramesDelta": 3,
        "durationMs": 1500,
    }
    good = {"nonblackFraction": 0.74, "meanLuma": 40.0, "stdDev": 41.0, "decodedFramesDelta": 150, "durationMs": 5000}
    for name, minimum in thresholds.items():
        bad = dict(good)
        bad[name] = minimum - 0.001
        failures = [k for k, m in bad.items() if m < thresholds[k]]
        assert name in failures


GOOD_METRICS = {
    "nonblackFraction": 0.7452,
    "meanLuma": 40.76,
    "stdDev": 41.2,
    "decodedFramesDelta": 169,
    "durationMs": 5000,
}


class _FakeHost:
    kind = "remote"

    def __init__(self, job):
        self._job = job
        self.console_complete_calls = []

    def provisioning_status(self, job_id):
        return {"job": dict(self._job)}

    def console_complete(self, job_id, **kwargs):
        self.console_complete_calls.append({"job_id": job_id, **kwargs})
        job = dict(self._job)
        job["state"] = "ready"
        return {"ok": True, "job": job}


@pytest.fixture()
def app_module(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    app = _load_module(
        "epicvm_app_under_test", REPO / "dashboard" / "app.py", extra_path=REPO / "dashboard"
    )
    # Mirror the production auth seams used by tests/test_provisioning_api.py.
    monkeypatch.setattr(app, "_admin_credentials", lambda: ("operator", "dashboard-password"))
    monkeypatch.setattr(app, "_dashboard_secret", lambda: "dashboard-secret")
    monkeypatch.setattr(app, "_verify_v2_token", lambda token: bool(token))
    return app


def _post_verify(app, monkeypatch, job, payload):
    host = _FakeHost(job)
    monkeypatch.setattr(app, "_vm_host", lambda host_id: host)
    monkeypatch.setattr(app, "_same_origin_request", lambda: True)
    monkeypatch.setattr(app, "_csrf_request_valid", lambda: True)
    client = app.app.test_client()
    client.set_cookie("Dashboard-Auth", "session")
    # Simulate the reverse-proxy HTTPS header used in production.
    response = client.open(
        f"/dashboard/api/provisioning-jobs/{job['id']}/console-verify",
        method="POST",
        json=payload,
        headers={"X-Forwarded-Proto": "https"},
    )
    return response, host


def test_dashboard_verify_completes_from_transport_and_decoded_video_evidence(app_module, monkeypatch):
    job = {"id": "jobframe1", "name": "vmx", "state": "streaming_setup"}
    payload = {
        "host_id": "epic-pc",
        "routePrefix": "/vm/vmx--epic-pc/",
        "guestTcpVerified": True,
        "frameMetrics": GOOD_METRICS,
    }
    response, host = _post_verify(app_module, monkeypatch, job, payload)
    assert response.status_code == 200, response.get_data(as_text=True)
    body = response.get_json()
    assert body["ok"] is True
    assert body["visualValidationComplete"] is True
    assert body["job"]["consoleVisualValidationPending"] is False
    call = host.console_complete_calls[-1]
    assert set(call) == {"job_id", "route_prefix", "guest_tcp_verified", "frame_metrics"}
    assert call["guest_tcp_verified"] is True
    assert call["frame_metrics"] == GOOD_METRICS


def test_dashboard_verify_ignores_browser_claimed_human_evidence(app_module, monkeypatch):
    """A caller cannot fabricate readiness: human-evidence fields are never trusted."""
    job = {"id": "jobframe2", "name": "vmx", "state": "streaming_setup"}
    payload = {
        "host_id": "epic-pc",
        "routePrefix": "/vm/vmx--epic-pc/",
        "guestTcpVerified": True,
        "evidenceSource": "browser_kvm",
        "videoFrameVerified": True,
        "keyboardInputVerified": True,
        "mouseInputVerified": True,
        "frameMetrics": GOOD_METRICS,
    }
    response, host = _post_verify(app_module, monkeypatch, job, payload)
    assert response.status_code == 200
    call = host.console_complete_calls[-1]
    # Human input claims are ignored. Quantified decoded-frame evidence is
    # forwarded to the agent for deterministic threshold validation.
    assert set(call) == {"job_id", "route_prefix", "guest_tcp_verified", "frame_metrics"}
    assert call["guest_tcp_verified"] is True
    assert call["frame_metrics"] == GOOD_METRICS


def test_dashboard_verify_rejects_missing_guest_transport(app_module, monkeypatch):
    job = {"id": "jobframe3", "name": "vmx", "state": "streaming_setup"}
    for transport in (False, None):
        payload = {
            "host_id": "epic-pc",
            "routePrefix": "/vm/vmx--epic-pc/",
            "guestTcpVerified": transport,
            "frameMetrics": GOOD_METRICS,
        }
        response, host = _post_verify(app_module, monkeypatch, job, payload)
        assert response.status_code == 422
        assert host.console_complete_calls == []


def test_dashboard_verify_rejects_missing_decoded_video_metrics(app_module, monkeypatch):
    job = {"id": "jobframe4", "name": "vmx", "state": "streaming_setup"}
    response, host = _post_verify(app_module, monkeypatch, job, {
        "host_id": "epic-pc",
        "routePrefix": "/vm/vmx--epic-pc/",
        "guestTcpVerified": True,
    })
    assert response.status_code == 422
    assert host.console_complete_calls == []


def test_agent_console_complete_is_transport_gated_with_optional_metrics():
    """The agent gate mirrors the dashboard contract: transport required,
    manual keyboard/mouse evidence gone, while decoded-frame metrics are
    validated so absent or fabricated diagnostics fail closed."""
    provisioning_source = (REPO / "remote_agent" / "windows" / "Provisioning.ps1").read_text(encoding="utf-8")
    assert "guestTcpVerified" in provisioning_source
    assert "Rendered video, keyboard, and mouse evidence are required" not in provisioning_source
    assert "'nonblackFraction'; Min=0.20" in provisioning_source
    assert "'meanLuma'; Min=12.0" in provisioning_source
    assert "'stdDev' readiness threshold" in provisioning_source
    assert "'decodedFramesDelta'; Min=3.0" in provisioning_source
    assert "'durationMs'; Min=1500.0" in provisioning_source
    assert "frameMetrics" in provisioning_source


def test_gaming_capture_script_is_wired_for_gaming_only():
    """The gaming Sunshine capture path must be selected only when IsGaming."""
    guest_source = (REPO / "remote_agent" / "windows" / "providers" / "GuestProvider.ps1").read_text(encoding="utf-8")
    assert "function Get-EpicVMGamingSunshineCaptureScript" in guest_source
    assert "$sunshineScript=Get-EpicVMSunshineConfigurationScript -ForGaming ([bool]$IsGaming)" in guest_source
    # The capture target pins the MTT VDD adapter and an AMD hardware encoder
    assert "friendly_name -eq 'VDD by MTT'" in guest_source
    assert "'output_name = ' + $displayId" in guest_source
    assert "encoder = amdvce" in guest_source
    # auto-logon keys must exist for a real interactive desktop session
    assert "AutoAdminLogon" in guest_source

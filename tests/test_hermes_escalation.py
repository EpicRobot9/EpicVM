import importlib.util
import json
import os
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_PATH = Path(os.environ.get("EPICVM_APP_PATH") or REPO_ROOT / "dashboard" / "app.py")
DASHBOARD_DIR = str(Path(APP_PATH).parent)


def load_app(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    if DASHBOARD_DIR not in sys.path:
        sys.path.insert(0, DASHBOARD_DIR)
    spec = importlib.util.spec_from_file_location("blobedash_test_hermes", APP_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    module._HERMES_ESCALATIONS.clear()
    return module


def test_escalation_uses_hermes_and_preserves_local_record(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    calls = []

    monkeypatch.setattr(module, "_vm_status_payload", lambda name, **_kwargs: {"running": False, "state": "exited"})
    monkeypatch.setattr(module, "_tail_vm_logs", lambda name, lines: "docker log excerpt")
    monkeypatch.setattr(module.subprocess, "run", lambda argv, **kwargs: calls.append((argv, kwargs)))

    result = module._escalate_vm_to_hermes("alpha", "VM did not start", {"recovery": {"recovered": False}})

    assert result["queued"] is True
    assert result["state"] == "queued"
    assert result["statusPath"].endswith(".status.json")
    assert calls == []
    status = json.loads(open(result["statusPath"], encoding="utf-8").read())
    assert status == {"state": "queued", "hostHandoff": True, "startedAt": result["payload"]["ts"]}
    assert result["path"]
    assert json.loads(open(result["path"], encoding="utf-8").read())["vm"] == "alpha"


def test_escalation_cooldown_rejects_spam_before_recovery_or_hermes(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._HERMES_ESCALATION_COOLDOWN_SECONDS = 300
    monkeypatch.setattr(module, "_vm_status_payload", lambda name: {"running": False})
    monkeypatch.setattr(module, "_tail_vm_logs", lambda name, lines: "")
    monkeypatch.setattr(module.subprocess, "run", lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("Hermes must not run twice")))

    first = module._claim_hermes_escalation("alpha", now=100.0)
    second = module._claim_hermes_escalation("alpha", now=101.0)

    assert first["allowed"] is True
    assert second["allowed"] is False
    assert second["retry_after"] == 299


def test_escalate_route_returns_429_for_rate_limited_request(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    monkeypatch.setattr(module, "_claim_hermes_escalation", lambda name: {"allowed": False, "retry_after": 42})
    client = module.app.test_client()

    response = client.post("/dashboard/api/vm/alpha/escalate", json={"reason": "again"})

    assert response.status_code == 429
    assert response.get_json() == {
        "ok": False,
        "error": "Hermes is already handling this VM",
        "retryAfter": 42,
    }


def test_escalate_route_recovers_then_hands_off_to_hermes(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    calls = []
    monkeypatch.setattr(module, "_claim_hermes_escalation", lambda name: {"allowed": True, "retry_after": 0})
    monkeypatch.setattr(module, "_recover_vm", lambda name, **kwargs: calls.append(("recover", name, kwargs)) or {"recovered": False})
    monkeypatch.setattr(module, "_escalate_vm_to_hermes", lambda name, reason, extra: calls.append(("hermes", name, reason, extra)) or {"queued": True})
    client = module.app.test_client()

    response = client.post("/dashboard/api/vm/alpha/escalate", json={"reason": "startup failed"})

    assert response.status_code == 200
    assert response.get_json()["escalation"]["queued"] is True
    assert calls[0][0] == "recover"
    assert calls[1][0:3] == ("hermes", "alpha", "startup failed")

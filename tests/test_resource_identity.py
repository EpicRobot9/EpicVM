import importlib.util
import sys
from pathlib import Path


APP_PATH = Path(__file__).resolve().parents[1] / "dashboard" / "app.py"
sys.path.insert(0, str(APP_PATH.parent))


def load_app(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setenv("DASH_V2_SECRET", "test-dashboard-secret")
    monkeypatch.setenv("BLOBEVM_USER_SECRET", "test-portal-secret")
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    spec = importlib.util.spec_from_file_location("resource_identity_test_app", str(APP_PATH))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_legacy_same_name_grant_fails_closed_as_ambiguous(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._init_users_db()
    with module._users_conn() as conn:
        user_id = conn.execute(
            "INSERT INTO users (username, password_hash, account_status) VALUES ('alice', 'x', 'approved')"
        ).lastrowid
        conn.execute("INSERT INTO user_vm_access (user_id, vm_name) VALUES (?, 'same')", (user_id,))
        conn.commit()

    resources = [
        {"resourceKey": module._resource_key("vm", "local", "same"), "resourceType": "vm", "hostId": "local", "name": "same"},
        {"resourceKey": module._resource_key("vm", "epic-pc", "guid-1"), "resourceType": "vm", "hostId": "epic-pc", "name": "same"},
    ]
    module._migrate_legacy_resource_access(resources)

    with module._users_conn() as conn:
        grant = conn.execute("SELECT resource_key, host_id FROM user_resource_access WHERE user_id = ?", (user_id,)).fetchone()
        issue = conn.execute("SELECT reason, candidates FROM resource_migration_issues").fetchone()
    assert grant["host_id"] == "unresolved"
    assert grant["resource_key"] == module._resource_key("vm", "unresolved", "same")
    assert issue["reason"] == "ambiguous_name"
    assert "vm:local:same" in issue["candidates"]
    assert "vm:epic-pc:guid-1" in issue["candidates"]


def test_same_name_resources_authorize_only_the_granted_host(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    local_key = module._resource_key("vm", "local", "same")
    remote_key = module._resource_key("vm", "epic-pc", "guid-1")
    module._init_users_db()
    with module._users_conn() as conn:
        for key, host, native in ((local_key, "local", "same"), (remote_key, "epic-pc", "guid-1")):
            conn.execute(
                """INSERT INTO resource_metadata
                   (resource_key, resource_type, host_id, native_id, display_name, access_mode)
                   VALUES (?, 'vm', ?, ?, 'same', 'restricted')""",
                (key, host, native),
            )
        conn.commit()
    user = {
        "username": "alice", "disabled": False, "accountStatus": "approved", "isAdmin": False,
        "assignedResources": [{"resourceKey": remote_key, "resourceType": "vm", "hostId": "epic-pc", "name": "same"}],
    }
    assert module._user_can_access_vm(user, "same", host_id="epic-pc", resource_key=remote_key) is True
    assert module._user_can_access_vm(user, "same", host_id="local", resource_key=local_key) is False


def test_access_request_approval_is_atomic_and_does_not_approve_account(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._init_users_db()
    key = module._resource_key("vm", "epic-pc", "guid-1")
    with module._users_conn() as conn:
        conn.execute("INSERT INTO users (username, password_hash, account_status) VALUES ('alice', 'x', 'pending')")
        conn.execute(
            """INSERT INTO resource_metadata
               (resource_key, resource_type, host_id, native_id, display_name, access_mode)
               VALUES (?, 'vm', 'epic-pc', 'guid-1', 'alpha', 'restricted')""",
            (key,),
        )
        request_id = conn.execute(
            """INSERT INTO access_requests
               (username, vm_name, resource_key, resource_type, host_id, status)
               VALUES ('alice', 'alpha', ?, 'vm', 'epic-pc', 'pending')""",
            (key,),
        ).lastrowid
        conn.commit()

    client = module.app.test_client()
    response = client.post(f"/dashboard/api/access-requests/{request_id}/action", json={"action": "approve"})
    assert response.status_code == 200
    repeat = client.post(f"/dashboard/api/access-requests/{request_id}/action", json={"action": "approve"})
    assert repeat.status_code == 200
    assert repeat.get_json()["repeated"] is True
    with module._users_conn() as conn:
        user = conn.execute("SELECT id, account_status FROM users WHERE username = 'alice'").fetchone()
        grants = conn.execute("SELECT resource_key FROM user_resource_access WHERE user_id = ?", (user["id"],)).fetchall()
        status = conn.execute("SELECT status FROM access_requests WHERE id = ?", (request_id,)).fetchone()["status"]
    assert user["account_status"] == "pending"
    assert [row["resource_key"] for row in grants] == [key]
    assert status == "approved"


def test_completed_legacy_request_is_history_not_an_unresolved_migration(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._init_users_db()
    with module._users_conn() as conn:
        request_id = conn.execute(
            """INSERT INTO access_requests (username, vm_name, status)
               VALUES ('Epic', 'retired-vm', 'approved')"""
        ).lastrowid
        conn.execute(
            """INSERT INTO resource_migration_issues
               (source_table, source_id, legacy_name, reason)
               VALUES ('access_requests', ?, 'retired-vm', 'resource_unavailable')""",
            (str(request_id),),
        )
        conn.commit()

    module._migrate_legacy_resource_access([])

    with module._users_conn() as conn:
        request_row = conn.execute(
            "SELECT status, resource_key FROM access_requests WHERE id = ?", (request_id,)
        ).fetchone()
        issue = conn.execute(
            "SELECT resolved_at FROM resource_migration_issues WHERE source_table = 'access_requests' AND source_id = ?",
            (str(request_id),),
        ).fetchone()
    assert request_row["status"] == "approved"
    assert request_row["resource_key"] is None
    assert issue["resolved_at"] is not None


def test_existing_session_is_revoked_when_account_is_rejected(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    module._init_users_db()
    with module._users_conn() as conn:
        conn.execute(
            "INSERT INTO users (username, password_hash, account_status) VALUES ('alice', ?, 'approved')",
            (module._hash_user_password("password"),),
        )
        conn.commit()
    token = module._create_portal_token("alice")
    assert module._verify_portal_token(token)["username"] == "alice"
    module._update_user("alice", account_status="rejected")
    assert module._verify_portal_token(token) is None
    assert module._verify_portal_token(token, require_approved=False) is None


def test_generic_cloudpc_start_dispatches_by_kind_before_public_vm_acl(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    user = {"username": "alice", "disabled": False, "accountStatus": "approved", "isAdmin": False, "assignedResources": []}
    monkeypatch.setattr(module, "_current_portal_user", lambda: user)
    monkeypatch.setattr(module, "_is_cloudpc", lambda name: name == "cloudpc-alice-1")
    monkeypatch.setattr(module, "_load_cloud_pc", lambda name: {"id": name, "owner": "alice"})
    monkeypatch.setattr(module, "_vm_access_mode", lambda *args, **kwargs: "public")
    calls = []
    monkeypatch.setattr(module, "_cp_start", lambda name: calls.append(name))
    monkeypatch.setattr(module, "_vm_host", lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("VM host dispatch must not run")))

    response = module.app.test_client().post(
        "/portal/api/start/cloudpc-alice-1", json={}, headers={"Origin": "http://localhost"}
    )
    assert response.status_code == 200
    assert response.get_json()["operation"] == "stream-start"
    assert calls == ["cloudpc-alice-1"]

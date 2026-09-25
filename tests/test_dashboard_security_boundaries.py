import io
import os
import stat
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_PATH = Path(os.environ.get("EPICVM_APP_PATH") or REPO_ROOT / "dashboard" / "app.py")


def load_app(monkeypatch, tmp_path):
    monkeypatch.setenv("BLOBEDASH_STATE", str(tmp_path))
    monkeypatch.setenv("DASH_V2_SECRET", "test-secret")
    monkeypatch.setenv("BLOBEVM_ALLOW_INSECURE_DASHBOARD", "1")
    if str(APP_PATH.parent) not in sys.path:
        sys.path.insert(0, str(APP_PATH.parent))
    import importlib.util

    spec = importlib.util.spec_from_file_location("blobedash_security_test_app", str(APP_PATH))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_vm_command_execution_is_disabled_without_running_docker(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    monkeypatch.setattr(
        module.subprocess,
        "run",
        lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("docker execution must not run")),
    )

    response = module.app.test_client().post(
        "/Dashboard/api/vm/exec/alpha",
        json={"cmd": "rm -rf /"},
    )

    assert response.status_code == 410
    assert response.get_json()["code"] == "capability_unsafe"


def test_favicon_uploads_reject_non_images_and_oversize_files(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    client = module.app.test_client()

    invalid = client.post(
        "/dashboard/api/upload-favicon",
        data={"file": (io.BytesIO(b"not an image"), "payload.svg")},
        content_type="multipart/form-data",
    )
    assert invalid.status_code == 400
    assert not (tmp_path / "dashboard" / "favicon.ico").exists()

    oversize = client.post(
        "/dashboard/api/upload-favicon",
        data={"file": (io.BytesIO(b"\x89PNG\r\n\x1a\n" + b"0" * module._FAVICON_MAX_BYTES), "large.png")},
        content_type="multipart/form-data",
    )
    assert oversize.status_code in {400, 413}


def test_valid_favicon_upload_is_atomic_and_private(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    response = module.app.test_client().post(
        "/dashboard/api/upload-favicon",
        data={"file": (io.BytesIO(b"\x89PNG\r\n\x1a\nminimal"), "favicon.png")},
        content_type="multipart/form-data",
    )

    assert response.status_code == 200
    saved = tmp_path / "dashboard" / "favicon.ico"
    assert saved.read_bytes().startswith(b"\x89PNG")
    if os.name != "nt":
        assert stat.S_IMODE(saved.stat().st_mode) == 0o600
    assert not list((tmp_path / "dashboard").glob(".favicon.*"))


def test_favicon_url_validation_blocks_ssrf_and_plain_http(monkeypatch, tmp_path):
    module = load_app(monkeypatch, tmp_path)
    for url in ("http://example.com/favicon.ico", "https://127.0.0.1/favicon.ico", "https://user:pass@example.com/favicon.ico"):
        try:
            module._validate_favicon_url(url)
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe favicon URL accepted: {url}")

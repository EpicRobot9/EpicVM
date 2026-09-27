"""Contract tests for EpicVM service descriptions and legacy service identity."""

from pathlib import Path
import re


REPO_ROOT = Path(__file__).resolve().parents[1]


def _text(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


def test_dashboard_service_has_epicvm_description_without_runtime_identity_changes():
    service = _text("server/blobedash.service")

    assert "Description=EpicVM Dashboard (direct mode)" in service
    assert "Description=BlobeVM Dashboard (direct mode)" not in service
    assert "ExecStart=/usr/bin/env bash /opt/blobe-vm/server/blobedash-ensure.sh" in service
    assert "ExecReload=/usr/bin/env bash /opt/blobe-vm/server/blobedash-ensure.sh" in service
    assert "ExecStop=/usr/bin/env docker rm -f blobedash" in service
    assert (REPO_ROOT / "server/blobedash.service").name == "blobedash.service"


def test_optimizer_compatibility_metadata_uses_epicvm_description():
    service = _text("blobe-optimizer.service")
    ensure_script = _text("optimizer/optimizer-ensure.sh")

    assert "EpicVM Optimizer" in service
    assert "legacy compatibility" in service.lower()
    assert "BlobeVM Optimizer" not in ensure_script
    assert "EpicVM Optimizer" in ensure_script
    assert "/opt/blobe-vm" in ensure_script


def test_installer_dashboard_auth_status_uses_epicvm_brand_only():
    installer = _text("server/install.sh")

    assert installer.count("EpicVM Dashboard Auth") == 2
    assert "BlobeVM Dashboard Auth" not in installer
    assert re.search(r'echo "  EpicVM Dashboard Auth: enabled', installer)
    assert re.search(r'echo "  EpicVM Dashboard Auth: disabled', installer)


def test_dashboard_secret_transport_uses_protected_env_file():
    ensure = _text("server/blobedash-ensure.sh")
    installer = _text("server/install.sh")
    assert '--env-file "$ENV_FILE"' in ensure
    assert "--env-file /opt/blobe-vm/.env" in installer
    for text in (ensure, installer):
        assert '-e BLOBEDASH_PASS=' not in text
        assert '-e DASH_V2_SECRET=' not in text
        assert '-e BLOBEVM_USER_SECRET=' not in text


def test_dashboard_image_pin_is_loaded_before_selection():
    ensure = _text("server/blobedash-ensure.sh")
    load_marker = "done < \"$ENV_FILE\""
    image_marker = 'IMAGE_NAME="${EPICVM_BLOBEDASH_IMAGE:-blobedash:local}"'
    assert ensure.index(load_marker) < ensure.index(image_marker)


def test_dashboard_passes_optional_moonlight_nat_host_to_runtime():
    ensure = _text("server/blobedash-ensure.sh")
    installer = _text("server/install.sh")
    runtime_arg = '-e EPICVM_MOONLIGHT_NAT_HOST="${EPICVM_MOONLIGHT_NAT_HOST:-}" \\'
    assert runtime_arg in ensure
    assert runtime_arg in installer
    assert 'echo "EPICVM_MOONLIGHT_NAT_HOST=$(sh_q "${EPICVM_MOONLIGHT_NAT_HOST:-}")";' in installer


def test_dashboard_image_hash_covers_every_runtime_module():
    ensure = _text("server/blobedash-ensure.sh")
    assert 'find "$STATE_DIR/dashboard" -maxdepth 1 -type f -name \'*.py\'' in ensure
    assert 'sha256sum "$STATE_DIR/server/blobedash.Dockerfile"' in ensure


def test_production_dashboard_uses_gunicorn_and_wsgi_entrypoint():
    dockerfile = _text("server/blobedash.Dockerfile")
    installer = _text("server/install.sh")
    assert "gunicorn==26.2.0" in dockerfile
    assert '"wsgi:app"' in dockerfile
    assert "gunicorn --bind 0.0.0.0:5000" in installer
    assert "wsgi:app" in installer
    assert (REPO_ROOT / "dashboard" / "wsgi.py").is_file()


def test_runtime_syncs_all_dashboard_python_modules_and_has_healthcheck():
    ensure = _text("server/blobedash-ensure.sh")
    dockerfile = _text("server/blobedash.Dockerfile")
    assert 'find "$REPO_DIR/dashboard" -maxdepth 1 -type f -name \'*.py\'' in ensure
    assert '[[ -n "${REPO_DIR:-}" && -d "$REPO_DIR/dashboard" ]]' in ensure
    assert 'REPO_DIR="${REPO_DIR:-/opt/blobe-vm/repo}"' not in ensure
    assert 'install -m 644 "$dashboard_source"' in ensure
    assert 'HEALTHCHECK' in dockerfile
    assert '/Dashboard/' in dockerfile

from pathlib import Path


REPO = Path(__file__).parents[1]
INSTALLER = (REPO / "install-epicvm.sh").read_text()
LEGACY_INSTALLER = (REPO / "install-blobevm.sh").read_text()
SERVER_INSTALLER = (REPO / "server/install.sh").read_text()
QUICK_INSTALLER = (REPO / "server/quick-install.sh").read_text()


def test_epicvm_is_the_full_installer_and_blobevm_is_a_compatibility_wrapper():
    assert "SCRIPT_NAME=\"${0##*/}\"" in INSTALLER
    assert "exec bash \"$SCRIPT_DIR/install-epicvm.sh\" \"$@\"" in LEGACY_INSTALLER
    assert LEGACY_INSTALLER.count('printf \'%s\\n\'') == 1


def test_bootstrap_settings_prefer_non_empty_epicvm_aliases():
    for name in ("BRANCH", "REPO_URL", "INSTALL_ROOT"):
        assert f'EPICVM_' in INSTALLER
    assert 'EPICVM_BRANCH:-${BLOBEVM_BRANCH:-main}' in INSTALLER
    assert 'EPICVM_REPO_URL:-${BLOBEVM_REPO_URL:-https://github.com/EpicRobot9/BlobeVM-Manager.git}' in INSTALLER
    assert 'EPICVM_ROOT:-${BLOBEVM_ROOT:-/opt/blobe-vm}' in INSTALLER


def test_server_normalizes_epicvm_aliases_once_before_downstream_logic():
    assert "normalize_epicvm_environment()" in SERVER_INSTALLER
    assert SERVER_INSTALLER.index("normalize_epicvm_environment()") < SERVER_INSTALLER.index("apply_env_overrides()")
    for name in (
        "DOMAIN",
        "EMAIL",
        "HTTP_PORT",
        "HTTPS_PORT",
        "ENABLE_DASHBOARD",
        "INITIAL_VM_NAME",
        "NO_TRAEFIK",
        "FORCE_REBUILD",
    ):
        assert f"EPICVM_{name}" in SERVER_INSTALLER


def test_quick_installer_accepts_epicvm_defaults_and_keeps_legacy_exports():
    assert "EPICVM_ASSUME_DEFAULTS" in QUICK_INSTALLER
    assert "EPICVM_ENABLE_DASHBOARD" in QUICK_INSTALLER
    assert "EPICVM_AUTO_CREATE_VM" in QUICK_INSTALLER
    assert "EPICVM_INITIAL_VM_NAME" in QUICK_INSTALLER
    assert "export BLOBEVM_ASSUME_DEFAULTS BLOBEVM_ENABLE_DASHBOARD BLOBEVM_AUTO_CREATE_VM BLOBEVM_INITIAL_VM_NAME" in QUICK_INSTALLER


def test_canonical_installers_use_epicvm_facing_copy():
    assert "BlobeVM Manager" not in INSTALLER
    assert "BlobeVM Host/VPS Installer" not in SERVER_INSTALLER


def test_clean_install_ships_the_complete_dashboard_runtime():
    assert 'find "$REPO_DIR/dashboard" -maxdepth 1 -type f -name \'*.py\'' in SERVER_INSTALLER
    assert 'install -Dm644 "$dashboard_module"' in SERVER_INSTALLER
    assert 'rsync -a --delete' in SERVER_INSTALLER
    assert '/opt/blobe-vm/epicvm_web/' in SERVER_INSTALLER


def test_dashboard_runtime_prefers_canonical_cli_and_keeps_legacy_alias():
    ensure = (REPO / "server" / "blobedash-ensure.sh").read_text()
    assert '-v /usr/local/bin/epicvm:/usr/local/bin/epicvm:ro' in ensure
    assert 'install -Dm755 "$REPO_DIR/server/blobe-vm-manager" /usr/local/bin/blobe-vm-manager' in SERVER_INSTALLER
    assert 'command -v epicvm' in QUICK_INSTALLER


def test_multiseat_overlay_is_checked_in_and_loaded_by_public_app():
    index = (REPO / "epicvm_web" / "index.html").read_text()
    overlay = REPO / "epicvm_web" / "public" / "management-multiseat.js"
    assert '<script type="module" src="/management-multiseat.js"></script>' in index
    assert '/management/host-gaming/desktop-grants' in overlay.read_text()

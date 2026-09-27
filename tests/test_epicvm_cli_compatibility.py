import os
import subprocess
from pathlib import Path

import pytest


REPO = Path(__file__).parents[1]
CANONICAL = REPO / "server" / "epicvm"
LEGACY = REPO / "server" / "blobe-vm-manager"


def run_cli(cli, *args):
    env = os.environ.copy()
    env["STATE_DIR"] = str(REPO / ".pytest-epicvm-state")
    command = [str(cli), *args]
    if os.name == "nt":
        bash = Path(r"C:\Program Files\Git\bin\bash.exe")
        if not bash.is_file():
            pytest.skip("Git Bash is required for the Bash CLI contract on Windows")
        command = [str(bash), *command]
    return subprocess.run(
        command,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_epicvm_is_the_canonical_executable_and_names_help_epicvm():
    result = run_cli(CANONICAL, "--help")

    assert result.returncode == 0
    assert "Usage: epicvm <command> [args]" in result.stderr


def test_legacy_launcher_preserves_legacy_help_name():
    result = run_cli(LEGACY, "--help")

    assert result.returncode == 0
    assert "Usage: blobe-vm-manager <command> [args]" in result.stderr


def test_legacy_launcher_execs_canonical_sibling_without_copying_implementation():
    launcher = LEGACY.read_text()

    assert 'exec "$SCRIPT_DIR/epicvm" "$@"' in launcher
    assert len(launcher.splitlines()) <= 12


def test_nuke_removes_canonical_and_legacy_installed_binaries():
    cli = CANONICAL.read_text()

    nuke = cli[cli.index("cmd_nuke() {"):]

    assert "rm -f /usr/local/bin/epicvm" in nuke
    assert "rm -f /usr/local/bin/blobe-vm-manager" in nuke


def test_doctor_checks_canonical_binary_and_reports_legacy_compatibility():
    cli = CANONICAL.read_text()

    doctor = cli[cli.index("cmd_doctor() {"):cli.index("cmd_nuke() {")]

    assert "-x /usr/local/bin/epicvm" in doctor
    assert "/usr/local/bin/epicvm" in doctor


def test_canonical_cli_has_epicvm_facing_copy():
    canonical = CANONICAL.read_text()

    assert "EpicVM CLI" in canonical
    assert "BlobeVM Manager" not in canonical
    assert "BlobeVM dashboard" not in canonical

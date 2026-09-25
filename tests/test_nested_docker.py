import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest


MANAGER = Path(__file__).parents[1] / "server" / "blobe-vm-manager"


def run_manager(tmp_path, *args):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    docker_log = tmp_path / "docker.log"
    docker = bin_dir / "docker"
    if not docker.exists():
        docker.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\0' \"$@\" >> \"$DOCKER_LOG\"\n"
            "if [[ \"${1:-}\" == ps ]]; then exit 0; fi\n"
        )
        docker.chmod(0o755)
    env = os.environ.copy()
    env.update({
        "STATE_DIR": str(tmp_path / "state"),
        "DOCKER_LOG": str(docker_log),
        "PATH": f"{bin_dir}:{env['PATH']}",
        "BLOBEVM_IMAGE": "test-image",
    })
    command = [str(MANAGER), *args]
    if os.name == "nt":
        bash = Path(r"C:\Program Files\Git\bin\bash.exe")
        if not bash.is_file():
            pytest.skip("Git Bash is required for the Bash CLI integration on Windows")
        if shutil.which("jq") is None:
            pytest.skip("jq is a required production runtime dependency for the nested Docker CLI")
        command = [str(bash), *command]
    return subprocess.run(
        command, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ), docker_log


def docker_invocations(log):
    values = log.read_bytes().split(b"\0")
    values = [value.decode() for value in values if value]
    invocations = []
    current = []
    for value in values:
        if value == "--name" and current:
            invocations.append(current)
            current = []
        current.append(value)
    if current:
        invocations.append(current)
    return invocations


def test_set_docker_off_persists_and_recreates_with_start_docker_false(tmp_path):
    result, log = run_manager(tmp_path, "create", "vm1")
    assert result.returncode == 0, result.stderr

    result, log = run_manager(tmp_path, "set-docker", "vm1", "off")

    assert result.returncode == 0, result.stderr
    metadata = json.loads((tmp_path / "state" / "instances" / "vm1" / "instance.json").read_text())
    assert metadata["start_docker"] == "off"
    assert "-e" in log.read_text(errors="ignore")
    assert "START_DOCKER=false" in log.read_text(errors="ignore")


def test_set_docker_on_passes_true_and_auto_clears_explicit_override(tmp_path):
    result, log = run_manager(tmp_path, "create", "vm1")
    assert result.returncode == 0, result.stderr

    result, log = run_manager(tmp_path, "set-docker", "vm1", "on")
    assert result.returncode == 0, result.stderr
    assert "START_DOCKER=true" in log.read_text(errors="ignore")

    result, log = run_manager(tmp_path, "set-docker", "vm1", "auto")

    assert result.returncode == 0, result.stderr
    metadata = json.loads((tmp_path / "state" / "instances" / "vm1" / "instance.json").read_text())
    assert "start_docker" not in metadata
    # The final recreation omits START_DOCKER, preserving the image default.
    invocations = docker_invocations(log)
    assert not any("START_DOCKER=true" in invocation or "START_DOCKER=false" in invocation for invocation in invocations[-1:])


def test_set_docker_rejects_invalid_value_without_recreating(tmp_path):
    result, log = run_manager(tmp_path, "create", "vm1")
    assert result.returncode == 0, result.stderr
    before = log.read_bytes()

    result, log = run_manager(tmp_path, "set-docker", "vm1", "sometimes")

    assert result.returncode != 0
    assert "on, off, or auto" in result.stderr
    assert log.read_bytes() == before


def test_set_docker_rejects_traversal_without_writing_outside_state(tmp_path):
    outside = tmp_path / "state" / "outside"
    outside.mkdir(parents=True)
    before = list(outside.iterdir())

    result, log = run_manager(tmp_path, "set-docker", "../outside", "off")

    assert result.returncode != 0
    assert "Invalid VM name" in result.stderr
    assert list(outside.iterdir()) == before
    assert not log.exists() or log.read_bytes() == b""


def test_default_start_docker_setting_is_not_added_to_docker_run(tmp_path):
    result, log = run_manager(tmp_path, "create", "vm1")

    assert result.returncode == 0, result.stderr
    assert "START_DOCKER=" not in log.read_text(errors="ignore")


def test_invalid_metadata_mode_is_normalized_to_auto(tmp_path):
    result, log = run_manager(tmp_path, "create", "vm1")
    assert result.returncode == 0, result.stderr
    metadata_path = tmp_path / "state" / "instances" / "vm1" / "instance.json"
    metadata_path.write_text(json.dumps({"start_docker": "unexpected"}))
    result, log = run_manager(tmp_path, "recreate", "vm1")
    assert result.returncode == 0, result.stderr
    assert "START_DOCKER=" not in log.read_text(errors="ignore")

    result, _ = run_manager(tmp_path, "list")

    assert result.returncode == 0, result.stderr
    assert "nested-docker=auto" in result.stdout

    docker = tmp_path / "bin" / "docker"
    docker.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        "printf '%s\\0' \"$@\" >> \"$DOCKER_LOG\"\n"
        "if [[ \"${1:-}\" == ps && \"${2:-}\" == -a ]]; then\n"
        "  printf '%s\\n' 'blobevm_vm1 Up 1 minute'\n"
        "  exit 0\n"
        "fi\n"
        "if [[ \"${1:-}\" == ps ]]; then exit 0; fi\n"
    )
    docker.chmod(0o755)
    result, _ = run_manager(tmp_path, "status", "vm1")

    assert result.returncode == 0, result.stderr
    assert "Nested Docker: auto" in result.stdout
